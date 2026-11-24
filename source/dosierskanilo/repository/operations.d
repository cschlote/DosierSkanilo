/** Repository write operations: scan, metadata, and analysis.
 *
 * The controlled variants honor cancellation and pause checkpoints and
 * commit each completed batch independently.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo.repository.operations;

import d2sqlite3;
import std.array : array;
import std.conv : to;
import std.exception : enforce;
import std.file : copy, exists, mkdirRecurse, remove;
import std.path : buildPath;
import std.string : empty, endsWith, startsWith;
import dosierarkivo.archive : archivePathSeparator, escapeArchiveVirtualPath;
import dosierskanilo.operations : OperationControl, OperationTarget;
import dosierskanilo.operationlease : TargetWriteLease;
import dosierskanilo.repository.errors;
import dosierskanilo.repository.analysis : analyzeRepositoryControlled;
import dosierskanilo.repository.metadata : updateRepositoryMetadataControlled;
import dosierskanilo.repository.scanner : scanRepositoryControlled;
import dosierskanilo.repository.types;
import dosierskanilo.repository.repository : Repository;

/** Members of `Repository` in the operations area; mixed into the class. */
mixin template RepositoryOperations()
{
    /** Scan the repository root and update its filesystem references.
     *
     * Params:
     *     options = Scan behavior and selection options.
     * Returns: Counters collected during the scan.
     */
    ScanSummary scan(RepositoryScanOptions options = RepositoryScanOptions())
    {
        requireOpen();
        return scanControlled(options, null, 0).summary;
    }

    /** Run a staged scan with operation progress, cancellation, and safe pauses.
     *
     * Params:
     *     options = Scan behavior and selection options.
     *     control = Operation control for progress and cancellation, or null.
     *     operationId = ID included in reported progress events.
     *     targetLease = Existing repository write lease, or null to acquire one.
     * Returns: Scan counters plus cancellation and commit flags.
     * Throws: `Exception` when a supplied lease belongs to another target.
     */
    package(dosierskanilo) ScanExecutionResult scanControlled(RepositoryScanOptions options,
        OperationControl control, ulong operationId,
        TargetWriteLease targetLease = null)
    {
        requireOpen();
        bool ownsLease = targetLease is null;
        if (ownsLease)
            targetLease = TargetWriteLease.acquireRepositoryRoot(
                repositoryPaths.rootPath);
        else
            enforce!RepositoryException(targetLease.owns(OperationTarget.repositoryTarget(
                repositoryPaths.rootPath)), "Operation lease target does not match repository.");
        scope (exit)
            if (ownsLease)
                targetLease.release();
        return scanRepositoryControlled(database, repositoryPaths.rootPath,
            options, control, operationId);
    }

    /** Run selected metadata extraction jobs for stored file references.
     *
     * Params:
     *     options = Metadata jobs and worker settings.
     * Returns: Counters collected during the metadata run.
     */
    MetadataSummary updateMetadata(
        MetadataScanOptions options = MetadataScanOptions())
    {
        requireOpen();
        return updateMetadataControlled(options, null, 0).summary;
    }

    /** Run metadata extraction with worker draining, blob transactions, and control.
     *
     * Params:
     *     options = Metadata jobs and worker settings.
     *     control = Operation control for progress and cancellation, or null.
     *     operationId = ID included in reported progress events.
     *     targetLease = Existing repository write lease, or null to acquire one.
     * Returns: Metadata counters plus cancellation and commit flags.
     * Throws: `Exception` when a supplied lease belongs to another target.
     */
    package(dosierskanilo) MetadataExecutionResult updateMetadataControlled(MetadataScanOptions options,
        OperationControl control, ulong operationId,
        TargetWriteLease targetLease = null)
    {
        requireOpen();
        bool ownsLease = targetLease is null;
        if (ownsLease)
            targetLease = TargetWriteLease.acquireRepositoryRoot(
                repositoryPaths.rootPath);
        else
            enforce!RepositoryException(targetLease.owns(OperationTarget.repositoryTarget(
                repositoryPaths.rootPath)), "Operation lease target does not match repository.");
        scope (exit)
            if (ownsLease)
                targetLease.release();
        return updateRepositoryMetadataControlled(database,
            repositoryPaths.rootPath, options, control, operationId);
    }

    /** Analyze missing references and duplicate blobs in SQL.
     *
     * Params:
     *     options = Analysis behavior and cleanup options.
     * Returns: Counters and results of the analysis.
     */
    AnalysisSummary analyze(
        RepositoryAnalysisOptions options = RepositoryAnalysisOptions())
    {
        requireOpen();
        return analyzeControlled(options, null, 0).summary;
    }

    /** Analyze the repository with staged plans and cooperative run control.
     *
     * Params:
     *     options = Analysis behavior and cleanup options.
     *     control = Operation control for progress and cancellation, or null.
     *     operationId = ID included in reported progress events.
     *     targetLease = Existing repository write lease, or null to acquire one.
     * Returns: Analysis counters plus cancellation and commit flags.
     * Throws: `Exception` when a supplied lease belongs to another target.
     */
    package(dosierskanilo) AnalysisExecutionResult analyzeControlled(RepositoryAnalysisOptions options,
        OperationControl control, ulong operationId,
        TargetWriteLease targetLease = null)
    {
        requireOpen();
        bool ownsLease = targetLease is null;
        if (ownsLease)
            targetLease = TargetWriteLease.acquireRepositoryRoot(
                repositoryPaths.rootPath);
        else
            enforce!RepositoryException(targetLease.owns(OperationTarget.repositoryTarget(
                repositoryPaths.rootPath)), "Operation lease target does not match repository.");
        scope (exit)
            if (ownsLease)
                targetLease.release();
        return analyzeRepositoryControlled(database, options, control, operationId);
    }
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

version (Windows) {} else
@("repository POSIX backslashes survive scan, metadata, and JSON roundtrip")
unittest
{
    import std.file : exists, mkdirRecurse, remove, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    const auto root = buildPath(tempDir(), "repository-backslash-"
        ~ randomUUID().toString());
    const auto importedRoot = buildPath(tempDir(), "repository-backslash-import-"
        ~ randomUUID().toString());
    const auto relativePath = "a\\b.txt";
    const auto filePath = buildPath(root, relativePath);
    const auto exported = buildPath(tempDir(), "repository-backslash-"
        ~ randomUUID().toString() ~ ".json");
    mkdirRecurse(root);
    mkdirRecurse(importedRoot);
    write(filePath, "backslash payload");
    scope (exit)
    {
        if (exists(root))
            rmdirRecurse(root);
        if (exists(importedRoot))
            rmdirRecurse(importedRoot);
        if (exists(exported))
            remove(exported);
    }

    auto repository = Repository.initialize(root);
    repository.scan();
    MetadataScanOptions metadataOptions;
    metadataOptions.calculateChecksums = true;
    const auto summary = repository.updateMetadata(metadataOptions);
    assert(summary.failed == 0);
    assert(summary.checksumsUpdated == 1);
    RepositoryFileQuery query;
    query.limit = 10;
    const auto files = repository.listFiles(query);
    assert(files.length == 1);
    assert(files[0].relativePath == relativePath);
    repository.exportJson(exported);
    repository.close();

    auto imported = Repository.initialize(importedRoot);
    imported.importJson(exported);
    const auto importedFiles = imported.listFiles(query);
    assert(importedFiles.length == 1);
    assert(importedFiles[0].relativePath == relativePath);
    imported.close();
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

    auto secondMetadataSummary = repository.updateMetadata(options);
    assert(secondMetadataSummary.checksumsUpdated == 0,
        "stored checksums must not be recalculated on a later metadata run");
    assert(secondMetadataSummary.fileTypesUpdated == 0,
        "stored file types must not be queried again on a later metadata run");
    assert(secondMetadataSummary.failed == 0);

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
    import dosierskanilo.testdata : ensureSyntheticTestCatalog;

    auto root = buildPath(tempDir(), "repository-rich-metadata-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    auto fixture = ensureSyntheticTestCatalog();
    copy(buildPath(fixture.catalogRoot, "images", "sample.bmp"),
        buildPath(root, "picture.bmp"));
    copy(buildPath(fixture.catalogRoot, "torrent", "single-file.torrent"),
        buildPath(root, "example.torrent"));
    scope (exit)
    {
        if (exists(root))
            rmdirRecurse(root);
    }

    auto repository = Repository.initialize(root);
    scope (exit)
        repository.close();
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

    const auto updatedBeforeAnalysis = repository.info.updatedAt;
    auto duplicates = repository.analyze();
    assert(duplicates.duplicateGroups == 1);
    assert(duplicates.mergedBlobs == 1);
    assert(repository.info.updatedAt != updatedBeforeAnalysis);

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
    import std.algorithm.searching : canFind, endsWith;
    import std.file : copy, exists, mkdirRecurse, remove, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.process : execute;
    import std.uuid : randomUUID;
    import dosierskanilo.testdata : ensureSyntheticTestCatalog;

    auto root = buildPath(tempDir(), "repository-rich-persistence-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    auto fixture = ensureSyntheticTestCatalog();
    auto payload = buildPath(root, "payload.txt");
    auto archive = buildPath(root, "payload.zip");
    auto torrent = buildPath(root, "example.torrent");
    write(payload, "repository archive payload\n");
    assert(execute(["zip", "-q", "-P", "repository-secret", "-j", archive,
        payload]).status == 0);
    copy(buildPath(fixture.catalogRoot, "torrent", "single-file.torrent"), torrent);
    auto exported = buildPath(root, "export.json");
    scope (exit)
    {
        if (exists(root))
            rmdirRecurse(root);
    }

    auto repository = Repository.initialize(root);
    scope (exit)
        repository.close();
    repository.scan();
    MetadataScanOptions options;
    options.calculateChecksums = true;
    options.detectFileTypes = true;
    options.scanArchives = true;
    options.scanTorrents = true;
    options.deepArchiveScan = false;
    size_t passwordPrompts;
    options.archivePasswordCallback = (string archivePath, string reason,
        out string password) {
        assert(archivePath == archive);
        assert(reason.length > 0);
        ++passwordPrompts;
        password = "repository-secret";
        return true;
    };
    auto summary = repository.updateMetadata(options);
    assert(summary.archivesUpdated == 1);
    assert(summary.torrentsUpdated == 1);
    assert(summary.failed == 0);
    RepositoryFileQuery archiveQuery;
    archiveQuery.archive = true;
    archiveQuery.limit = 10;
    auto archiveFiles = repository.listFiles(archiveQuery);
    string archiveFilePaths;
    foreach (file; archiveFiles)
        archiveFilePaths ~= "[" ~ file.relativePath ~ "]";
    assert(archiveFiles.length == 1, archiveFilePaths);
    assert(archiveFiles[0].hasArchive);
    JsonExportOptions lazyDetails;
    lazyDetails.includeArchiveEntries = false;
    lazyDetails.includeTorrentFiles = false;
    auto archiveBlob = repository.loadBlobDetails(archiveFiles[0].blobId, lazyDetails);
    assert(archiveBlob !is null);
    assert(repository.hasArchiveIndex(archiveFiles[0].blobId));
    RepositoryArchiveQuery archiveEntriesQuery;
    archiveEntriesQuery.blobId = archiveFiles[0].blobId;
    auto archiveEntriesBefore = repository.listArchiveEntries(archiveEntriesQuery);
    assert(archiveEntriesBefore.length > 0);
    assert(archiveEntriesBefore[0].hasSafePath);
    assert(archiveEntriesBefore[0].relativePath == "payload.txt");
    assert(archiveEntriesBefore[0].contentBlobId > 0,
        "Every safe virtual member is an ordinary content blob.");
    const auto stableArchiveEntryId = archiveEntriesBefore[0].id;
    options.deepArchiveScan = true;
    repository.updateMetadata(options);
    assert(passwordPrompts == 1);
    auto deepArchiveEntries = repository.listArchiveEntries(archiveEntriesQuery);
    assert(deepArchiveEntries[0].id == stableArchiveEntryId);
    const auto summaryBefore = repository.archiveEntrySummary(
        archiveFiles[0].blobId);
    assert(summaryBefore.entryCount == deepArchiveEntries.length,
        "The aggregated summary counts the indexed members.");
    assert(summaryBefore.completeFingerprints == deepArchiveEntries.length,
        "Deep-scanned members carry complete fingerprints.");
    assert(deepArchiveEntries[0].contentBlobId > 0,
        "Deep archive checksums preserve a normal member content identity.");
    RepositoryFileQuery payloadQuery;
    payloadQuery.text = "payload.txt";
    auto physicalPayloads = repository.listFiles(payloadQuery);
    assert(physicalPayloads.length == 1);
    assert(deepArchiveEntries[0].contentBlobId == physicalPayloads[0].blobId,
        "Equal archive and filesystem payloads should reuse one blob.");
    JsonExportOptions memberDetailsOptions;
    memberDetailsOptions.allowUnreferencedContent = true;
    auto memberDetails = repository.loadBlobDetails(
        deepArchiveEntries[0].contentBlobId, memberDetailsOptions);
    assert(memberDetails !is null && memberDetails.fileSpecs.length == 2);
    bool foundPhysicalPayload;
    bool foundVirtualPayload;
    foreach (spec; memberDetails.fileSpecs)
    {
        foundPhysicalPayload = foundPhysicalPayload
            || spec.fileName == "payload.txt";
        foundVirtualPayload = foundVirtualPayload
            || spec.fileName.endsWith("!/payload.txt");
    }
    assert(foundPhysicalPayload && foundVirtualPayload);
    assert(memberDetails.checkSums.hasDigests);
    assert(memberDetails.fileType.length > 0);
    options.rescan = true;
    repository.updateMetadata(options);
    auto archiveEntriesAfter = repository.listArchiveEntries(archiveEntriesQuery);
    assert(archiveEntriesAfter.length == deepArchiveEntries.length);
    assert(archiveEntriesAfter[0].id == stableArchiveEntryId,
        "An unchanged archive entry should retain its repository identity.");
    options.rescan = false;
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
    bool foundVirtualMember;
    foreach (blob; blobs)
    {
        if (blob.archivePassword == "repository-secret")
            foundArchive = true;
        foreach (spec; blob.fileSpecs)
            if (spec.fileName.canFind(archivePathSeparator()))
                foundVirtualMember = true;
        if (blob.torrentInfo !is null)
            foundTorrent = true;
    }
    assert(foundArchive && foundVirtualMember);
    assert(foundTorrent);
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
    import dosierskanilo.testdata : ensureSyntheticTestCatalog;

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
    auto fixture = ensureSyntheticTestCatalog();
    auto torrentSeed = buildPath(fixture.catalogRoot, "torrent",
        "single-file.torrent");
    copy(torrentSeed, firstPath);
    copy(torrentSeed, secondPath);

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

@("repository metadata scan can target one archive path")
unittest
{
    import std.algorithm.searching : endsWith;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.process : execute;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "repository-targeted-archive-scan-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    auto firstPayload = buildPath(root, "first.txt");
    auto secondPayload = buildPath(root, "second.txt");
    auto firstArchive = buildPath(root, "first.zip");
    auto secondArchive = buildPath(root, "second.zip");
    write(firstPayload, "first payload");
    write(secondPayload, "second payload");
    assert(execute(["zip", "-q", "-j", firstArchive, firstPayload]).status == 0);
    assert(execute(["zip", "-q", "-j", secondArchive, secondPayload]).status == 0);
    scope (exit)
    {
        if (exists(root))
            rmdirRecurse(root);
    }

    auto repository = Repository.initialize(root);
    scope (exit)
        repository.close();
    repository.scan();

    MetadataScanOptions options;
    options.scanArchives = true;
    options.deepArchiveScan = false;
    options.filePath = "first.zip";
    auto summary = repository.updateMetadata(options);
    assert(summary.blobsVisited == 1);
    assert(summary.archivesUpdated == 1);
    assert(summary.failed == 0);
    auto secondSummary = repository.updateMetadata(options);
    assert(secondSummary.archivesUpdated == 0,
        "a current archive index must not be generated again");
    assert(secondSummary.failed == 0);

    bool foundFirst;
    bool foundSecond;
    bool foundFirstMember;
    foreach (blob; repository.loadCatalog())
    {
        auto fileName = blob.getFirstFileName;
        if (fileName == "first.zip")
        {
            foundFirst = true;
            assert(blob.archiveIndexKnown);
        }
        else if (fileName == "second.zip")
        {
            foundSecond = true;
            assert(!blob.archiveIndexKnown);
        }
        foreach (spec; blob.fileSpecs)
            foundFirstMember = foundFirstMember
                || spec.fileName.endsWith("!/first.txt");
    }
    assert(foundFirst && foundSecond && foundFirstMember);
}

@("archive indexing handles container names with exclamation marks")
unittest
{
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.process : execute;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "repo-bang-archive-"
        ~ randomUUID().toString());
    mkdirRecurse(buildPath(root, "weird!"));
    scope (exit)
    {
        if (exists(root))
            rmdirRecurse(root);
    }
    write(buildPath(root, "inside.txt"), "inside\n");
    assert(execute(["zip", "-q", "-j",
        buildPath(root, "weird!", "name.zip"),
        buildPath(root, "inside.txt")]).status == 0);

    auto repository = Repository.initialize(root);
    scope (exit)
        repository.close();
    repository.scan();
    MetadataScanOptions options;
    options.scanArchives = true;
    options.deepArchiveScan = true;
    const summary = repository.updateMetadata(options);

    const containerReference = repository.fileReferenceByRelativePath(
        escapeArchiveVirtualPath("weird!/name.zip"));
    assert(containerReference.id > 0);
    RepositoryArchiveQuery query;
    query.blobId = containerReference.blobId;
    query.limit = 10;
    const entries = repository.listArchiveEntries(query);
    assert(entries.length == 1, "entries=" ~ entries.length.to!string
        ~ " updated=" ~ summary.archivesUpdated.to!string
        ~ " failed=" ~ summary.failed.to!string);
    assert(entries[0].name == "inside.txt");
}

@("archive-only rescan rebuilds current archive indexes")
unittest
{
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.process : execute;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "repository-archive-rescan-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
    {
        if (exists(root))
            rmdirRecurse(root);
    }
    auto payload = buildPath(root, "payload.txt");
    auto archive = buildPath(root, "bundle.zip");
    write(payload, "payload");
    assert(execute(["zip", "-q", "-j", archive, payload]).status == 0);

    auto repository = Repository.initialize(root);
    scope (exit)
        repository.close();
    repository.scan();

    MetadataScanOptions options;
    options.scanArchives = true;
    options.deepArchiveScan = false;
    const auto first = repository.updateMetadata(options);
    assert(first.archivesUpdated == 1);

    const auto unchanged = repository.updateMetadata(options);
    assert(unchanged.archivesUpdated == 0,
        "a current archive index must not be generated again");

    MetadataScanOptions archivesOnly;
    archivesOnly.scanArchives = true;
    archivesOnly.deepArchiveScan = false;
    archivesOnly.rescanArchives = true;
    assert(archivesOnly.archiveRescan);
    assert(!archivesOnly.rescan);
    const auto rebuilt = repository.updateMetadata(archivesOnly);
    assert(rebuilt.archivesUpdated == 1,
        "an archive-only rescan must rebuild the current index");
    assert(rebuilt.mediaInfoUpdated == 0);
    assert(rebuilt.checksumsUpdated == 0);
    assert(rebuilt.failed == 0);
}

@("archive-only metadata cancellation finishes the current archive and resumes")
unittest
{
    import dosierskanilo.operations : OperationPhase, OperationProgress,
        OperationState;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.process : execute;
    import std.uuid : randomUUID;

    const root = buildPath(tempDir(), "repository-archive-resume-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);
    write(buildPath(root, "one.txt"), "one");
    write(buildPath(root, "two.txt"), "two");
    assert(execute(["zip", "-q", "-j", buildPath(root, "one.zip"),
        buildPath(root, "one.txt")]).status == 0);
    assert(execute(["zip", "-q", "-j", buildPath(root, "two.zip"),
        buildPath(root, "two.txt")]).status == 0);

    auto repository = Repository.initialize(root);
    scope (exit)
        repository.close();
    repository.scan();

    MetadataScanOptions options;
    options.scanArchives = true;
    options.deepArchiveScan = true;
    options.threads = 1;

    OperationControl control;
    control = new OperationControl((OperationProgress event) {
        if (event.phase == OperationPhase.archives
            && event.state == OperationState.running
            && event.completed == 2)
            control.requestCancellation();
    });
    auto first = repository.updateMetadataControlled(options, control, 1);
    assert(first.cancelled);
    assert(first.committed);
    assert(first.summary.archivesUpdated == 1,
        first.summary.archivesUpdated.to!string);
    assert(first.summary.blobsVisited == 2,
        first.summary.blobsVisited.to!string);

    options.archiveLimit = 1;
    auto second = repository.updateMetadataControlled(options, null, 2);
    assert(!second.cancelled);
    assert(second.summary.archivesUpdated == 1,
        second.summary.archivesUpdated.to!string);
    assert(second.summary.blobsVisited == 1,
        second.summary.blobsVisited.to!string);

    auto third = repository.updateMetadataControlled(options, null, 3);
    assert(!third.cancelled);
    assert(third.summary.archivesUpdated == 0);
    assert(third.summary.blobsVisited == 0,
        "a finished archive-only run must select no pending archives");
}

@("archive member scans resume from a persisted partial index")
unittest
{
    import dosierskanilo.archivebulk : ArchiveBulkMode;
    import dosierskanilo.operations : OperationPhase, OperationProgress,
        OperationState;
    import std.algorithm : map;
    import std.algorithm.searching : canFind;
    import std.array : array;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.process : execute;
    import std.uuid : randomUUID;

    const root = buildPath(tempDir(), "repository-member-resume-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);
    string[] files;
    foreach (index; 0 .. 8)
    {
        const name = "member-" ~ index.to!string ~ ".txt";
        write(buildPath(root, name), "payload-" ~ index.to!string);
        files ~= name;
    }
    const archivePath = buildPath(root, "bundle.zip");
    auto created = execute(["zip", "-q", "-j", archivePath]
        ~ files.map!(name => buildPath(root, name)).array);
    assert(created.status == 0, created.output);

    auto repository = Repository.initialize(root);
    scope (exit)
        repository.close();
    repository.scan();

    MetadataScanOptions options;
    options.scanArchives = true;
    options.deepArchiveScan = true;
    options.threads = 1;
    options.archiveBulkMode = ArchiveBulkMode.always;

    OperationControl control;
    control = new OperationControl((OperationProgress event) {
        if (event.phase == OperationPhase.archives
            && event.state == OperationState.running
            && event.subtaskTotalKnown
            && event.subtaskCompleted >= 3)
            control.requestCancellation();
    });
    auto first = repository.updateMetadataControlled(options, control, 1);
    assert(first.cancelled);
    assert(first.committed);
    assert(first.summary.archivesUpdated == 1,
        first.summary.archivesUpdated.to!string);
    assert(first.summary.blobsVisited == 1,
        first.summary.blobsVisited.to!string);

    auto partial = repository.database.execute("SELECT state, "
        ~ "extractor_version FROM metadata_status WHERE "
        ~ "metadata_kind = 'archives'");
    assert(!partial.empty);
    assert(partial.front.peek!string(0) == "partial",
        partial.front.peek!string(0));
    assert(partial.front.peek!string(1).canFind(":partial:"),
        partial.front.peek!string(1));
    const partialMembers = repository.database.execute("SELECT count(*) "
        ~ "FROM file_refs WHERE relative_path LIKE ?", "%!/%")
        .oneValue!long;
    assert(partialMembers > 0 && partialMembers < 8,
        partialMembers.to!string);

    auto second = repository.updateMetadataControlled(options, null, 2);
    assert(!second.cancelled);
    assert(second.committed);
    assert(second.summary.archivesUpdated == 1,
        second.summary.archivesUpdated.to!string);
    assert(second.summary.failed == 0,
        second.summary.lastError);
    auto completed = repository.database.execute("SELECT state, "
        ~ "extractor_version FROM metadata_status WHERE "
        ~ "metadata_kind = 'archives'");
    assert(!completed.empty);
    assert(completed.front.peek!string(0) == "completed",
        completed.front.peek!string(0));
    assert(completed.front.peek!string(1).endsWith(":deep"),
        completed.front.peek!string(1));
    const completedMembers = repository.database.execute("SELECT count(*) "
        ~ "FROM file_refs WHERE relative_path LIKE ?", "%!/%")
        .oneValue!long;
    assert(completedMembers == 8, completedMembers.to!string);

    auto third = repository.updateMetadataControlled(options, null, 3);
    assert(!third.cancelled);
    assert(third.summary.archivesUpdated == 0);
    assert(third.summary.blobsVisited == 0);
}

@("deep archive scans persist encrypted member metadata on content blobs")
unittest
{
    import std.algorithm.searching : canFind, endsWith;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.process : Config, execute;
    import std.uuid : randomUUID;

    const root = buildPath(tempDir(), "repository-deep-member-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);
    write(buildPath(root, "payload.txt"), "secret payload\n");
    assert(execute(["zip", "-q", "-P", "archive-secret", "-j",
        "private.zip", "payload.txt"], null, Config.none, size_t.max,
        root).status == 0);

    auto repository = Repository.initialize(root);
    scope (exit)
        repository.close();
    repository.scan();

    MetadataScanOptions options;
    options.scanArchives = true;
    options.deepArchiveScan = true;
    options.detectFileTypes = true;
    size_t passwordPrompts;
    options.archivePasswordCallback = (string path, string reason,
        out string password) {
        ++passwordPrompts;
        password = "archive-secret";
        return true;
    };
    const summary = repository.updateMetadata(options);
    assert(summary.archivesUpdated == 1, summary.failed.to!string);
    assert(summary.failed == 0);
    assert(passwordPrompts == 1);

    RepositoryFileQuery containerQuery;
    containerQuery.archive = true;
    const containers = repository.listFiles(containerQuery);
    assert(containers.length == 1);
    const container = containers[0];
    assert(repository.loadBlobDetails(container.blobId).archivePassword
        == "archive-secret");

    RepositoryFileQuery memberQuery;
    memberQuery.includeArchiveMembers = true;
    memberQuery.text = "private.zip!/payload.txt";
    memberQuery.limit = 10;
    RepositoryFile member;
    foreach (file; repository.listFiles(memberQuery))
        if (file.archiveMember && file.relativePath.endsWith("!/payload.txt"))
            member = file;
    assert(member.id > 0);
    assert(member.blobId > 0);
    const details = repository.loadBlobDetails(member.blobId);
    assert(details.checkSums.hasDigests);
    assert(details.fileType.length > 0);
    foreach (spec; details.fileSpecs)
        assert(!spec.fileName.startsWith(".dosierskanilo")
            && !spec.fileName.canFind(".tmp-"),
            "member metadata must not reference the temporary cache path");
}
