/** Unittests for the JSON catalog adapter.
 *
 *
 * Tests build fixtures in temporary directories and compare backend results.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo.jsoncatalogbackendtests;

import std.algorithm.searching : canFind, startsWith;
import std.algorithm.sorting : sort;
import std.conv : to;
import std.datetime.systime : SysTime;
import std.file : exists, getSize;
import std.path : baseName, buildPath, dirName;
import std.uuid : randomUUID;
import dosierarkivo.archive : archivePathEscapeSequence;
import dosierskanilo.catalogbackend;
import dosierskanilo.metadata.mediainfosig : MediaInfoSig;
import dosierskanilo.model.archivespec : ArchiveSpec;
import dosierskanilo.model.checksums : CheckSums;
import dosierskanilo.model.filespec : FileSpec;
import dosierskanilo.model.namedbinaryblob : DATA_CLASS_VERSION5,
    NamedBinaryBlob, NamedBinaryBlobCatalog,
    deserializeDataClassJsonWrapperFile, serializeDataClassWrapperFile;
import dosierskanilo.operationrunner;
import dosierskanilo.operations : AnalysisOperationRequest, OperationControl,
    OperationKind, OperationState, OperationStorageMode, OperationTarget,
    ScanOperationRequest;
import dosierskanilo.jsoncatalogbackend : JsonCatalogBackend,
    JsonCatalogBackendFactory;

version (unittest)
{
    import std.algorithm.searching : canFind;
    import std.file : DirEntry, SpanMode, dirEntries, exists, getcwd, getSize,
        read, remove, rmdirRecurse, tempDir, write;
    import std.path : baseName;
    import std.uuid : randomUUID;
    import dosierskanilo.model.namedbinaryblob :
        deserializeDataClassJsonWrapperFile;
    import dosierskanilo.operations : OperationState;
    import dosierskanilo.testdata : copySyntheticCatalogForTest;

    @("JSON directory filters include non-BMP descendants")
    unittest
    {
        import std.conv : to;
        import std.datetime.systime : SysTime;
        import dosierskanilo.model.namedbinaryblob :
            serializeDataClassWrapperFile;
        const token = randomUUID().toString();
        const catalogPath = buildPath(tempDir(), "json-nonbmp-" ~ token ~ ".json");
        scope (exit)
            if (exists(catalogPath))
                remove(catalogPath);

        NamedBinaryBlobCatalog catalog;
        catalog.dataVersion = DATA_CLASS_VERSION5;
        catalog.dataArray = [
            new NamedBinaryBlob("media/\U0001F600.txt", 5, SysTime(0)),
            new NamedBinaryBlob("media/out.txt", 7, SysTime(0)),
            new NamedBinaryBlob("other/plain.txt", 5, SysTime(0))
        ];
        serializeDataClassWrapperFile(catalogPath, catalog);

        auto backend = new JsonCatalogBackend(
            OperationTarget.jsonTarget(catalogPath, tempDir()));
        scope (exit)
            backend.close();

        CatalogDirectoryQuery query;
        query.filter.pathText = "\U0001F600";
        CatalogPageRequest request;
        request.limit = 10;
        const page = backend.listDirectories(query, request);
        assert(page.directories.length == 1);
        assert(page.directories[0].name == "media");

        /* Filtered counts must describe matching content only, like SQLite. */
        CatalogDirectoryQuery unfiltered;
        const plainPage = backend.listDirectories(unfiltered, request);
        assert(plainPage.directories.length == 2);
        foreach (directory; plainPage.directories)
        {
            const mediaDirectory = directory.name == "media";
            assert(directory.fileCount == (mediaDirectory ? 2 : 1),
                directory.fileCount.to!string);
            assert(directory.aggregateSize == (mediaDirectory ? 12UL : 5UL),
                directory.aggregateSize.to!string);
        }

        /* pathText filter: one matching directory with matching counts only. */
        assert(page.directories[0].fileCount == 1,
            page.directories[0].fileCount.to!string);
        assert(page.directories[0].aggregateSize == 5,
            page.directories[0].aggregateSize.to!string);
    }

    @("JSON filtered directory counts use immediate files")
    unittest
    {
        import std.datetime.systime : SysTime;
        import dosierskanilo.model.namedbinaryblob :
            serializeDataClassWrapperFile;

        const token = randomUUID().toString();
        const catalogPath = buildPath(tempDir(), "json-count-" ~ token ~ ".json");
        scope (exit)
            if (exists(catalogPath))
                remove(catalogPath);
        NamedBinaryBlobCatalog catalog;
        catalog.dataVersion = DATA_CLASS_VERSION5;
        catalog.dataArray = [
            new NamedBinaryBlob("parent/one.txt", 1, SysTime(0)),
            new NamedBinaryBlob("parent/child/two.txt", 2, SysTime(0)),
            new NamedBinaryBlob("parent/child/three.txt", 3, SysTime(0))
        ];
        serializeDataClassWrapperFile(catalogPath, catalog);

        auto backend = new JsonCatalogBackend(
            OperationTarget.jsonTarget(catalogPath, tempDir()));
        scope (exit)
            backend.close();
        CatalogPageRequest request;
        request.limit = 10;
        CatalogDirectoryQuery nested;
        nested.filter.pathText = "two";
        const nestedPage = backend.listDirectories(nested, request);
        assert(nestedPage.directories.length == 1);
        assert(nestedPage.directories[0].fileCount == 0,
            "a matching nested file is not an immediate child");
        assert(nestedPage.directories[0].aggregateSize == 2);

        CatalogDirectoryQuery immediate;
        immediate.filter.pathText = "parent";
        const immediatePage = backend.listDirectories(immediate, request);
        assert(immediatePage.directories.length == 1);
        assert(immediatePage.directories[0].fileCount == 1,
            "only parent/one.txt is an immediate child");
        assert(immediatePage.directories[0].aggregateSize == 6);
    }

    @("JSON backend indexes and operates on the generated catalog without SQLite")
    unittest
    {
        auto token = randomUUID().toString();
        auto root = copySyntheticCatalogForTest(buildPath(tempDir(),
            "json-catalog-backend-" ~ token));
        auto catalogPath = buildPath(tempDir(), "json-catalog-backend-"
            ~ token ~ ".json");
        auto exportPath = buildPath(tempDir(), "json-catalog-backend-export-"
            ~ token ~ ".json");
        auto backupPrefix = baseName(catalogPath)[0 .. $ - ".json".length] ~ "-";
        CatalogBackend backend;
        scope (exit)
        {
            if (backend !is null)
                backend.close();
            if (exists(catalogPath))
                remove(catalogPath);
            if (exists(exportPath))
                remove(exportPath);
            foreach (DirEntry entry; dirEntries(getcwd(), SpanMode.shallow))
                if (entry.name.baseName.startsWith(backupPrefix)
                    && exists(entry.name))
                    remove(entry.name);
            if (exists(root))
                rmdirRecurse(root);
        }

        auto factory = new JsonCatalogBackendFactory();
        auto target = OperationTarget.jsonTarget(catalogPath, root);
        backend = factory.open(target);
        assert(backend.capabilities().supports(OperationKind.scan));
        assert(backend.capabilities().supports(OperationKind.analyze));
        assert(!backend.capabilities().supports(OperationKind.metadata));
        assert(backend.capabilities().supportsTreeQueries);

        ScanOperationRequest scan;
        scan.operationId = 1;
        scan.target = backend.target();
        scan.scanOptions.recursive = true;
        scan.metadataOptions.calculateChecksums = true;
        scan.metadataOptions.detectFileTypes = true;
        scan.metadataOptions.extractMediaInfo = true;
        scan.metadataOptions.scanArchives = true;
        scan.metadataOptions.deepArchiveScan = true;
        scan.metadataOptions.scanTorrents = true;
        scan.metadataOptions.threads = 2;
        const auto scanned = backend.runOperation(scan, new OperationControl());
        assert(scanned.state == OperationState.completed, scanned.error);
        assert(scanned.changesCommitted);
        assert(scanned.scanSummary.filesAdded == 12);
        assert(scanned.metadataSummary.checksumsUpdated == 12);
        assert(scanned.metadataSummary.archivesUpdated == 3);
        assert(scanned.metadataSummary.torrentsUpdated == 2);
        assert(!exists(buildPath(root, ".dosierskanilo")),
            "the explicit JSON adapter must not initialize SQLite");

        auto rootSummary = backend.rootSummary();
        assert(rootSummary.fileReferenceCount == 12);
        CatalogDirectoryQuery directoryQuery;
        CatalogPageRequest directoryPageRequest;
        directoryPageRequest.limit = 32;
        auto directoryPage = backend.listDirectories(directoryQuery,
            directoryPageRequest);
        DirectoryId archiveDirectory;
        DirectoryId mediaDirectory;
        DirectoryId torrentDirectory;
        foreach (directory; directoryPage.directories)
        {
            if (directory.relativePath == "archives")
                archiveDirectory = directory.id;
            else if (directory.relativePath == "media")
                mediaDirectory = directory.id;
            else if (directory.relativePath == "torrent")
                torrentDirectory = directory.id;
        }
        assert(archiveDirectory.isValid && mediaDirectory.isValid
            && torrentDirectory.isValid);

        CatalogFileQuery archiveQuery;
        archiveQuery.directoryId = archiveDirectory;
        archiveQuery.filter.archive = true;
        CatalogPageRequest backwardsRequest;
        backwardsRequest.limit = 1;
        auto archivePage = backend.listFiles(archiveQuery, backwardsRequest);
        assert(archivePage.files.length == 1 && archivePage.hasMore);
        const auto secondArchivePage = backend.nextFilesPage(archiveQuery,
            archivePage.nextCursor);
        assert(secondArchivePage.hasMore);
        const auto backToSecond = backend.previousFilesPage(archiveQuery,
            secondArchivePage.nextCursor);
        assert(backToSecond.files.length == 1);
        assert(backToSecond.files[0].relativePath
            == secondArchivePage.files[0].relativePath);
        const auto backToFirst = backend.previousFilesPage(archiveQuery,
            backToSecond.previousCursor);
        assert(backToFirst.files.length == 1);
        assert(backToFirst.files[0].relativePath
            == archivePage.files[0].relativePath);
        assert(!backToFirst.hasPrevious);

        CatalogFileQuery sizeQuery;
        sizeQuery.directoryId = archiveDirectory;
        sizeQuery.sortOrder = CatalogSortOrder.sizeDescending;
        auto sizePage = backend.listFiles(sizeQuery);
        assert(sizePage.files.length == 3);
        foreach (index; 1 .. sizePage.files.length)
            assert(sizePage.files[index - 1].size >= sizePage.files[index].size);
        CatalogPageRequest sizeRequest;
        sizeRequest.limit = 1;
        auto sizeFirst = backend.listFiles(sizeQuery, sizeRequest);
        auto sizeSecond = backend.nextFilesPage(sizeQuery, sizeFirst.nextCursor);
        assert(sizeFirst.files[0].relativePath == sizePage.files[0].relativePath);
        assert(sizeSecond.files[0].relativePath == sizePage.files[1].relativePath);

        auto afterFirstSize = backend.listFilesFrom(sizeQuery,
            sizePage.files[0].relativePath, true, 1);
        assert(afterFirstSize.files.length == 1);
        assert(afterFirstSize.files[0].relativePath
            == sizePage.files[1].relativePath);
        auto beforeSecondSize = backend.listFilesFrom(sizeQuery,
            sizePage.files[1].relativePath, false, 1);
        assert(beforeSecondSize.files.length == 1);
        assert(beforeSecondSize.files[0].relativePath
            == sizePage.files[0].relativePath);
        assert(backend.listFilesFrom(sizeQuery,
            sizePage.files[0].relativePath, false, 1).files.length == 0);
        assert(backend.listFilesFrom(sizeQuery,
            sizePage.files[$ - 1].relativePath, true, 1).files.length == 0);
        assert(backend.listFilesFrom(sizeQuery, "missing.bin", true, 1)
            .files.length == 0);
        const auto sizeFromEmpty = backend.listFilesFrom(sizeQuery, "", true, 2);
        assert(sizeFromEmpty.files.length == 2 && sizeFromEmpty.hasMore);
        assert(sizeFromEmpty.files[0].relativePath
            == sizePage.files[0].relativePath);

        const auto allContents = backend.listContents(CatalogContentQuery.init);
        assert(allContents.total > 0);
        assert(allContents.rows.length == allContents.total);
        foreach (row; allContents.rows)
        {
            assert(row.id.isValid);
            assert(row.referenceCount > 0);
            assert(row.displayPath.length > 0);
        }
        CatalogPageRequest contentRequest;
        contentRequest.limit = 2;
        const auto firstContents = backend.listContents(
            CatalogContentQuery.init, contentRequest);
        assert(firstContents.rows.length == 2 && firstContents.hasMore);
        const auto nextContents = backend.listContents(
            CatalogContentQuery.init,
            CatalogPageRequest(2, firstContents.nextCursor));
        assert(nextContents.rows.length == 2);
        assert(nextContents.total == allContents.total);
        assert(nextContents.hasPrevious);
        assert(nextContents.rows[0].displayPath
            != firstContents.rows[1].displayPath);
        CatalogContentQuery archiveContents;
        archiveContents.filter.pathText = "sample.zip";
        assert(backend.listContents(archiveContents).rows.length >= 1);

        auto passwordTarget = archivePage.files[0];
        const auto passwordName = baseName(passwordTarget.relativePath);
        backend.setArchivePassword(passwordTarget.relativePath, "catalog-secret");
        {
            const auto stored = deserializeDataClassJsonWrapperFile(catalogPath);
            bool found;
            foreach (blob; stored.dataArray)
                foreach (spec; blob.fileSpecs)
                    if (spec !is null && baseName(spec.fileName) == passwordName
                        && blob.archivePassword == "catalog-secret")
                        found = true;
            assert(found);
        }
        backend.setArchivePassword(passwordTarget.relativePath, "");
        {
            const auto stored = deserializeDataClassJsonWrapperFile(catalogPath);
            foreach (blob; stored.dataArray)
                foreach (spec; blob.fileSpecs)
                    if (spec !is null && baseName(spec.fileName) == passwordName)
                        assert(blob.archivePassword.length == 0);
        }

        /* A read failure is reported as a typed backend error and leaves the
         * previous catalog file untouched. */
        {
            const auto saved = read(catalogPath);
            scope (exit)
                write(catalogPath, saved);
            write(catalogPath, "not a catalog");
            bool readFailureTyped;
            try
                backend.setArchivePassword(passwordName, "secret");
            catch (CatalogBackendException failure)
                readFailureTyped = failure.code
                    == CatalogBackendErrorCode.backendFailure;
            assert(readFailureTyped);
            assert(read(catalogPath) == "not a catalog");
        }
        bool rejectedUnknownPasswordPath;
        try
            backend.setArchivePassword("missing.bin", "secret");
        catch (CatalogBackendException failure)
            rejectedUnknownPasswordPath = failure.code
                == CatalogBackendErrorCode.invalidIdentifier;
        assert(rejectedUnknownPasswordPath);

        archivePage = backend.listFiles(archiveQuery);
        assert(archivePage.files.length == 3);
        CatalogFile sampleArchive;
        foreach (file; archivePage.files)
            if (file.name == "sample.zip")
                sampleArchive = file;
        assert(sampleArchive.contentId.isValid);
        auto archiveEntries = backend.listArchiveEntries(sampleArchive.contentId);
        assert(archiveEntries.entries.length == 7);
        assert(archiveEntries.entries[0].hasSafePath);
        assert(archiveEntries.entries[0].contentId.isValid);
        CatalogDetailMask archiveMemberDetails;
        archiveMemberDetails.fingerprint = true;
        auto archiveMember = backend.loadContent(
            archiveEntries.entries[0].contentId, archiveMemberDetails);
        assert(archiveMember.fingerprint.complete);
        CatalogPageRequest archiveMemberRequest;
        archiveMemberRequest.limit = 1;
        auto archiveMembers = backend.listArchiveMembers(
            sampleArchive.referenceId, archiveMemberRequest);
        assert(archiveMembers.members.length == 1 && archiveMembers.hasMore);
        assert(archiveMembers.members[0].locator.kind
            == ContentLocator.Kind.archiveEntry);
        assert(archiveMembers.members[0].contentId.isValid);
        string archiveEntryNames;
        foreach (entry; archiveEntries.entries)
            archiveEntryNames ~= "[" ~ entry.name ~ "]";
        assert(archiveEntries.entries.canFind!((entry) =>
            entry.name == "payload/copy.txt"), archiveEntryNames);
        assert(archiveEntries.entries[0].fingerprint.complete);

        /* Removing the container after indexing refreshes member availability. */
        const auto sampleArchivePath = buildPath(root, "archives", "sample.zip");
        const auto sampleArchiveBytes = read(sampleArchivePath);
        remove(sampleArchivePath);
        auto unavailableMembers = backend.listArchiveMembers(
            sampleArchive.referenceId, archiveMemberRequest);
        assert(unavailableMembers.members.length == 1);
        assert(unavailableMembers.members[0].availability
            == CatalogReferenceAvailability.unavailable);
        write(sampleArchivePath, sampleArchiveBytes);
        auto availableMembers = backend.listArchiveMembers(
            sampleArchive.referenceId, archiveMemberRequest);
        assert(availableMembers.members[0].availability
            == CatalogReferenceAvailability.available);

        /* Typed handles and path-based restoration stay storage-neutral. */
        assert(backend.uiHandle(sampleArchive.referenceId).startsWith("ref:"));
        assert(backend.uiHandle(archiveDirectory).startsWith("dir:"));
        assert(backend.uiHandle(sampleArchive.contentId).startsWith("content:"));
        assert(backend.uiHandle(sampleArchive.referenceId)
            != backend.uiHandle(sampleArchive.contentId));
        assert(backend.resolveDirectory("archives") == archiveDirectory);
        assert(!backend.resolveDirectory("").isValid);
        assert(!backend.resolveDirectory("archives/missing").isValid);
        assert(backend.resolveReference(sampleArchive.relativePath)
            == sampleArchive.referenceId);
        assert(!backend.resolveReference("archives/missing.zip").isValid);
        assert(backend.loadReference(sampleArchive.referenceId).relativePath
            == sampleArchive.relativePath);
        bool unknownReferenceRejected;
        try
            backend.loadReference(ReferenceId.init);
        catch (CatalogBackendException failure)
            unknownReferenceRejected = failure.code
                == CatalogBackendErrorCode.invalidIdentifier;
        assert(unknownReferenceRejected);

        /* Nested members extract through the shared leased cache. */
        CatalogPageRequest allMemberRequest;
        allMemberRequest.limit = 64;
        CatalogArchiveMember nestedArchiveMember;
        foreach (member; backend.listArchiveMembers(sampleArchive.referenceId,
            allMemberRequest).members)
            if (member.name == "nested.zip")
                nestedArchiveMember = member;
        assert(nestedArchiveMember.referenceId.isValid);
        const auto nestedMemberPage = backend.listArchiveMembers(
            nestedArchiveMember.referenceId, allMemberRequest);
        assert(nestedMemberPage.members.length == 1);
        assert(backend.resolveReference(
            "archives/sample.zip!/nested.zip!/deep/readme.txt").isValid);
        auto nestedLease = backend.acquireMemberContent(
            nestedMemberPage.members[0].referenceId);
        assert(exists(nestedLease.path));
        assert(getSize(nestedLease.path) == nestedMemberPage.members[0].size);
        nestedLease.release();

        CatalogFileQuery mediaQuery;
        mediaQuery.directoryId = mediaDirectory;
        mediaQuery.filter.audio = true;
        auto mediaPage = backend.listFiles(mediaQuery);
        assert(mediaPage.files.length == 1);
        CatalogDetailMask mediaDetails;
        mediaDetails.fingerprint = true;
        mediaDetails.media = true;
        auto media = backend.loadContent(mediaPage.files[0].contentId, mediaDetails);
        assert(media.fingerprint.complete);
        assert(media.mediaStreams.length == 1);
        assert(media.mediaStreams[0].kind == CatalogMediaKind.audio);

        /* Availability is checked when the page is served, not when indexed. */
        const auto mediaFilePath = buildPath(root, "media",
            mediaPage.files[0].name);
        const auto mediaBytes = read(mediaFilePath);
        remove(mediaFilePath);
        auto unavailableMedia = backend.listFiles(mediaQuery);
        assert(unavailableMedia.files.length == 1);
        assert(unavailableMedia.files[0].availability
            == CatalogReferenceAvailability.unavailable);
        write(mediaFilePath, mediaBytes);
        auto availableMedia = backend.listFiles(mediaQuery);
        assert(availableMedia.files[0].availability
            == CatalogReferenceAvailability.available);

        CatalogFileQuery torrentQuery;
        torrentQuery.directoryId = torrentDirectory;
        torrentQuery.filter.torrent = true;
        auto torrentPage = backend.listFiles(torrentQuery);
        assert(torrentPage.files.length == 2);
        CatalogFile singleTorrent;
        foreach (file; torrentPage.files)
            if (file.name == "single-file.torrent")
                singleTorrent = file;
        assert(singleTorrent.hasTorrent);
        CatalogDetailMask torrentDetails;
        torrentDetails.torrentSummary = true;
        const auto torrentContent = backend.loadContent(singleTorrent.contentId,
            torrentDetails);
        assert(torrentContent.torrentSummary.name == "tone.wav");
        assert(torrentContent.torrentSummary.totalSize == 76);
        assert(!torrentContent.torrentSummary.fileListAvailable);
        assert(!backend.capabilities().supportsTorrentEntryQueries,
            "The legacy source catalog contains no torrent file list.");
        bool torrentDetailUnavailable;
        try
            backend.listTorrentEntries(singleTorrent.contentId);
        catch (CatalogBackendException failure)
            torrentDetailUnavailable = failure.code
                == CatalogBackendErrorCode.unsupportedFeature;
        assert(torrentDetailUnavailable);

        CatalogExportOptions exportOptions;
        exportOptions.format = CatalogExportFormat.jsonV5;
        exportOptions.outputPath = exportPath;
        CatalogSubsetQuery subsetQuery;
        subsetQuery.pathPrefix = "archives";
        const auto exported = backend.exportSubset(subsetQuery, exportOptions);
        assert(exported.committed);
        assert(exported.referencesExported > 3);
        const auto exportedCatalog = deserializeDataClassJsonWrapperFile(exportPath);
        assert(exportedCatalog.dataVersion == DATA_CLASS_VERSION5);
        assert(exportedCatalog.dataArray.length > 3);

        auto missingPath = buildPath(root, "same-size", "different.txt");
        remove(missingPath);
        AnalysisOperationRequest analyze;
        analyze.operationId = 2;
        analyze.target = OperationTarget.jsonTarget(catalogPath, root);
        const auto retained = backend.runOperation(analyze, new OperationControl());
        assert(retained.state == OperationState.completed, retained.error);
        assert(retained.analysisSummary.missingFiles == 1);
        assert(retained.analysisSummary.droppedFiles == 0);
        DirectoryId missingDirectory;
        foreach (directory; backend.listDirectories(CatalogDirectoryQuery.init,
            directoryPageRequest).directories)
            if (directory.relativePath == "same-size")
                missingDirectory = directory.id;
        assert(missingDirectory.isValid);
        auto missingQuery = CatalogFileQuery.init;
        missingQuery.directoryId = missingDirectory;
        missingQuery.filter.pathText = "different.txt";
        auto retainedMissing = backend.listFiles(missingQuery);
        assert(retainedMissing.files.length == 1);
        assert(retainedMissing.files[0].availability
            == CatalogReferenceAvailability.unavailable);

        analyze.operationId = 3;
        analyze.options.dropMissing = true;
        const auto dropped = backend.runOperation(analyze, new OperationControl());
        assert(dropped.state == OperationState.completed, dropped.error);
        assert(dropped.analysisSummary.droppedFiles == 1);
        assert(backend.rootSummary().fileReferenceCount == 11);
    }

    @("JSON backend reads legacy arrays and v1-v3 wrapper representations")
    unittest
    {
        auto factory = new JsonCatalogBackendFactory();
        foreach (catalogPath; ["test/json_file_v0.json", "test/json_file_v1.json",
            "test/json_file_v2.json", "test/json_file_v2_archive.json",
            "test/json_file_v2_torrent.json", "test/json_file_wrapper_v2.json"])
        {
            auto target = OperationTarget.jsonTarget(catalogPath, "test");
            auto backend = factory.open(target);
            assert(backend.capabilities().supportsTreeQueries, catalogPath);
            assert(backend.rootSummary().fileReferenceCount > 0, catalogPath);
            backend.close();

            auto analysisOnly = factory.open(OperationTarget.jsonTarget(catalogPath));
            assert(!analysisOnly.capabilities().supportsTreeQueries, catalogPath);
            assert(analysisOnly.capabilities().supports(OperationKind.analyze));
            analysisOnly.close();
        }
    }

    @("JSON backend retains malformed catalogs unless overwrite is explicit")
    unittest
    {
        import std.file : exists, readText, remove, tempDir, write;
        import std.path : baseName, buildPath;

        auto token = randomUUID().toString();
        auto catalogPath = buildPath(tempDir(), "json-backend-malformed-"
            ~ token ~ ".json");
        auto backupPrefix = baseName(catalogPath)[0 .. $ - ".json".length] ~ "-";
        write(catalogPath, "not JSON");
        scope (exit)
        {
            if (exists(catalogPath))
                remove(catalogPath);
            foreach (DirEntry entry; dirEntries(getcwd(), SpanMode.shallow))
                if (entry.name.baseName.startsWith(backupPrefix)
                    && exists(entry.name))
                    remove(entry.name);
        }

        auto factory = new JsonCatalogBackendFactory();
        auto target = OperationTarget.jsonTarget(catalogPath);
        auto backend = factory.open(target);
        scope (exit)
            backend.close();
        AnalysisOperationRequest analyze;
        analyze.operationId = 51;
        analyze.target = target;
        const auto rejected = backend.runOperation(analyze, new OperationControl());
        assert(rejected.state == OperationState.failed);
        assert(!rejected.changesCommitted);
        assert(readText(catalogPath) == "not JSON");

        analyze.operationId = 52;
        analyze.forceJsonOverwrite = true;
        const auto replaced = backend.runOperation(analyze, new OperationControl());
        assert(replaced.state == OperationState.completed, replaced.error);
        assert(replaced.changesCommitted);
        assert(deserializeDataClassJsonWrapperFile(catalogPath).dataArray.length == 0);
    }
    @("JSON archive member pages merge physical and member sort orders")
    unittest
    {
        import std.algorithm.mutation : reverse;
        import std.datetime.systime : Clock;
        import dosierskanilo.model.archivespec : ArchiveSpec;
        import dosierskanilo.model.checksums : CheckSums;
        import dosierskanilo.model.namedbinaryblob : DATA_CLASS_VERSION5,
            NamedBinaryBlob, NamedBinaryBlobCatalog,
            serializeDataClassWrapperFile;

        const token = randomUUID().toString();
        const root = buildPath(tempDir(), "json-member-pages-" ~ token);
        const catalogPath = buildPath(tempDir(), "json-member-pages-"
            ~ token ~ ".json");
        scope (exit)
        {
            if (exists(catalogPath))
                remove(catalogPath);
            if (exists(root))
                rmdirRecurse(root);
        }

        auto container = new NamedBinaryBlob("archive.zip", 100,
            Clock.currTime());
        container.archiveSpecs = [
            new ArchiveSpec("c.txt", 3, "2020-01-02T04:04:06", CheckSums.init),
            new ArchiveSpec("a.txt", 1, "2020-01-02T04:04:06", CheckSums.init),
            new ArchiveSpec("b.txt", 2, "2020-01-02T04:04:06", CheckSums.init)
        ];
        container.archiveIndexKnown = true;
        container.archiveIndexDeep = true;
        NamedBinaryBlobCatalog catalog;
        catalog.dataVersion = DATA_CLASS_VERSION5;
        catalog.dataArray = [
            container,
            new NamedBinaryBlob("plain.txt", 4, Clock.currTime())
        ];
        serializeDataClassWrapperFile(catalogPath, catalog);

        auto backend = new JsonCatalogBackend(
            OperationTarget.jsonTarget(catalogPath, root));
        scope (exit)
            backend.close();

        CatalogFileQuery query;
        query.filter.includeArchiveMembers = true;
        string[] collect(CatalogFileQuery current)
        {
            string[] paths;
            CatalogPageRequest request;
            request.limit = 2;
            auto page = backend.listFiles(current, request);
            foreach (file; page.files)
                paths ~= file.relativePath;
            while (page.hasMore)
            {
                page = backend.nextFilesPage(current, page.nextCursor);
                foreach (file; page.files)
                    paths ~= file.relativePath;
            }
            return paths;
        }

        const string[] pathAscending = ["archive.zip", "archive.zip!/a.txt",
            "archive.zip!/b.txt", "archive.zip!/c.txt", "plain.txt"];
        assert(collect(query) == pathAscending);

        query.sortOrder = CatalogSortOrder.pathDescending;
        assert(collect(query) == pathAscending.dup.reverse);

        query.sortOrder = CatalogSortOrder.sizeAscending;
        assert(collect(query) == ["archive.zip!/a.txt", "archive.zip!/b.txt",
            "archive.zip!/c.txt", "plain.txt", "archive.zip"]);

        query.sortOrder = CatalogSortOrder.sizeDescending;
        assert(collect(query) == ["archive.zip", "plain.txt",
            "archive.zip!/c.txt", "archive.zip!/b.txt", "archive.zip!/a.txt"]);

        query.sortOrder = CatalogSortOrder.pathAscending;
        CatalogPageRequest firstRequest;
        firstRequest.limit = 2;
        const auto firstPage = backend.listFiles(query, firstRequest);
        const auto secondPage = backend.nextFilesPage(query,
            firstPage.nextCursor);
        const auto backPage = backend.previousFilesPage(query,
            secondPage.previousCursor);
        assert(firstPage.files.length == 2 && secondPage.files.length == 2);
        assert(backPage.files[0].relativePath == firstPage.files[0].relativePath);
        assert(backPage.files[1].relativePath == firstPage.files[1].relativePath);
    }

    @("JSON backend folds double-escaped archive members into their container")
    unittest
    {
        import std.datetime.systime : Clock;
        import dosierskanilo.model.namedbinaryblob : DATA_CLASS_VERSION5,
            FileSpec, NamedBinaryBlob, NamedBinaryBlobCatalog,
            serializeDataClassWrapperFile;

        const token = randomUUID().toString();
        const root = buildPath(tempDir(), "json-double-escaped-" ~ token);
        const catalogPath = buildPath(tempDir(), "json-double-escaped-"
            ~ token ~ ".json");
        scope (exit)
            if (exists(catalogPath))
                remove(catalogPath);

        auto container = new NamedBinaryBlob();
        container.fileSize = 14;
        container.fileSpecs = [new FileSpec("archives/test.zip", "")];
        container.fileSpecsUseArchiveVirtualGrammar = true;

        auto stale = new NamedBinaryBlob();
        stale.fileSize = 0;
        stale.fileSpecs = [new FileSpec(
            "archives/test.zip!!/member.txt", "")];
        stale.fileSpecsUseArchiveVirtualGrammar = true;

        auto member = new NamedBinaryBlob();
        member.fileSize = 6;
        member.fileSpecs = [new FileSpec(
            "archives/test.zip!/member.txt", "")];
        member.fileSpecsUseArchiveVirtualGrammar = true;

        NamedBinaryBlobCatalog catalog;
        catalog.dataVersion = DATA_CLASS_VERSION5;
        /* Keep the stale projection before the indexed member so the size
         * preference has to resolve the duplicate. */
        catalog.dataArray = [container, stale, member];
        serializeDataClassWrapperFile(catalogPath, catalog);

        auto backend = new JsonCatalogBackend(
            OperationTarget.jsonTarget(catalogPath, root));
        scope (exit)
            backend.close();

        assert(backend.capabilities().supportsTreeQueries);
        const auto archiveDirectory = backend.resolveDirectory("archives");
        assert(archiveDirectory.isValid);
        CatalogFileQuery query;
        query.directoryId = archiveDirectory;
        query.filter.includeArchiveMembers = true;
        query.sortOrder = CatalogSortOrder.pathAscending;
        CatalogPageRequest request;
        request.limit = 32;
        const auto page = backend.listFiles(query, request);
        string[] paths;
        foreach (file; page.files)
            paths ~= file.relativePath;
        const string[] expected = ["archives/test.zip",
            "archives/test.zip!/member.txt"];
        assert(paths == expected, paths.to!string);

        ulong memberSize;
        foreach (file; page.files)
            if (file.relativePath == "archives/test.zip!/member.txt")
                memberSize = file.size;
        assert(memberSize == 6, memberSize.to!string);

        CatalogDirectoryQuery directoryQuery;
        directoryQuery.parentId = archiveDirectory;
        const auto directoryPage = backend.listDirectories(directoryQuery,
            request);
        foreach (directory; directoryPage.directories)
            assert(!directory.relativePath.canFind(
                archivePathEscapeSequence()), directory.relativePath);
    }

}

@("JSON document sessions keep explicit save and discard semantics")
unittest
{
    import dosierskanilo.model.namedbinaryblob : NamedBinaryBlobCatalog,
        serializeDataClassWrapperFile;
    import std.datetime.systime : Clock;
    import std.file : exists, mkdirRecurse, remove, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    const token = randomUUID().toString();
    const root = buildPath(tempDir(), "json-document-" ~ token);
    const catalogPath = buildPath(tempDir(), "json-document-" ~ token ~ ".json");
    mkdirRecurse(root);
    scope (exit)
    {
        if (exists(root))
            rmdirRecurse(root);
        if (exists(catalogPath))
            remove(catalogPath);
    }
    write(buildPath(root, "first.txt"), "first");
    NamedBinaryBlobCatalog emptyCatalog = NamedBinaryBlobCatalog(
        DATA_CLASS_VERSION5, []);
    serializeDataClassWrapperFile(catalogPath, emptyCatalog);

    auto backend = new JsonCatalogBackend(
        OperationTarget.jsonTarget(catalogPath, root));
    scope (exit)
        backend.close();
    assert(backend.capabilities().persistence
        == CatalogPersistence.inMemoryDocument);

    auto document = backend.document();
    assert(!document.modified());

    ScanOperationRequest scan;
    scan.operationId = 1;
    scan.target = backend.target();
    scan.scanOptions.recursive = true;
    const applied = document.applyScan(scan, new OperationControl());
    assert(applied.state == OperationState.completed, applied.error);
    assert(document.modified());
    assert(!applied.changesCommitted);
    assert(backend.rootSummary().fileReferenceCount == 1);

    document.discard();
    assert(!document.modified());
    assert(backend.rootSummary().fileReferenceCount == 0);

    scan.operationId = 2;
    assert(document.applyScan(scan, new OperationControl()).state
        == OperationState.completed);
    document.save();
    assert(!document.modified());

    auto reloaded = new JsonCatalogBackend(
        OperationTarget.jsonTarget(catalogPath, root));
    scope (exit)
        reloaded.close();
    assert(reloaded.rootSummary().fileReferenceCount == 1);

    /* An external catalog change must not be overwritten silently. */
    scan.operationId = 3;
    assert(document.applyScan(scan, new OperationControl()).state
        == OperationState.completed);
    write(catalogPath, "{\"dataVersion\":5,\"dataArray\":[]}");
    bool rejected;
    try
        document.save();
    catch (CatalogBackendException failure)
        rejected = failure.code == CatalogBackendErrorCode.writeConflict;
    assert(rejected, "saving over an externally changed catalog must fail");
}

@("JSON document dry-run leaves buffer and index unchanged")
unittest
{
    import dosierskanilo.model.filespec : FileSpec;
    import dosierskanilo.model.namedbinaryblob : NamedBinaryBlobCatalog,
        serializeDataClassWrapperFile;
    import std.file : exists, mkdirRecurse, remove, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    const root = buildPath(tempDir(), "json-document-dry-run-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);
    write(buildPath(root, "a.txt"), "alpha");
    const catalogPath = buildPath(tempDir(), "json-document-dry-run-"
        ~ randomUUID().toString() ~ ".json");
    scope (exit)
        if (exists(catalogPath))
            remove(catalogPath);
    auto blob = new NamedBinaryBlob([new FileSpec("a.txt", "")], 5);
    NamedBinaryBlobCatalog catalog = NamedBinaryBlobCatalog(DATA_CLASS_VERSION5,
        [blob]);
    serializeDataClassWrapperFile(catalogPath, catalog);

    auto backend = new JsonCatalogBackend(
        OperationTarget.jsonTarget(catalogPath, root));
    scope (exit)
        backend.close();
    auto document = backend.document();
    const before = backend.listFiles(CatalogFileQuery.init).files.length;
    assert(before == 1);

    ScanOperationRequest request;
    request.operationId = 1;
    request.target = backend.target();
    request.scanOptions.recursive = true;
    request.dryRun = true;
    assert(document.applyScan(request, new OperationControl()).state
        == OperationState.completed);
    assert(!document.modified());
    assert(backend.listFiles(CatalogFileQuery.init).files.length == before,
        "a dry-run must not update the live index");

    write(buildPath(root, "b.txt"), "beta");
    request.operationId = 2;
    request.dryRun = false;
    assert(document.applyScan(request, new OperationControl()).state
        == OperationState.completed);
    assert(document.modified());
    assert(backend.listFiles(CatalogFileQuery.init).files.length
        == before + 1);
}

@("JSON document save detects changes before document creation")
unittest
{
    import dosierskanilo.model.filespec : FileSpec;
    import dosierskanilo.model.namedbinaryblob : NamedBinaryBlobCatalog,
        serializeDataClassWrapperFile;
    import std.datetime.systime : Clock;
    import std.file : exists, mkdirRecurse, remove, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    const token = randomUUID().toString();
    const root = buildPath(tempDir(), "json-save-race-" ~ token);
    const catalogPath = root ~ ".json";
    mkdirRecurse(root);
    scope (exit)
    {
        if (exists(root))
            rmdirRecurse(root);
        if (exists(catalogPath))
            remove(catalogPath);
    }
    write(buildPath(root, "a.txt"), "payload");
    auto blob = new NamedBinaryBlob([new FileSpec("a.txt", "")], 7);
    NamedBinaryBlobCatalog catalog = NamedBinaryBlobCatalog(DATA_CLASS_VERSION5,
        [blob]);
    serializeDataClassWrapperFile(catalogPath, catalog);

    auto backend = new JsonCatalogBackend(
        OperationTarget.jsonTarget(catalogPath, root));
    scope (exit)
        backend.close();

    /* Change the file between backend load and the first document() call. */
    write(catalogPath, "{\"dataVersion\":5,\"dataArray\":[]}");
    auto document = backend.document();
    AnalysisOperationRequest request;
    request.operationId = 1;
    request.target = backend.target();
    assert(document.applyAnalysis(request, new OperationControl()).state
        == OperationState.completed);
    bool rejected;
    try
        document.save();
    catch (CatalogBackendException failure)
        rejected = failure.code == CatalogBackendErrorCode.writeConflict;
    assert(rejected,
        "the load-time fingerprint must survive until the first save");
}

@("JSON document save stores base-relative references and drops outside paths")
unittest
{
    import dosierskanilo.model.filespec : FileSpec;
    import dosierskanilo.model.namedbinaryblob : NamedBinaryBlobCatalog,
        deserializeDataClassJsonWrapperFile, serializeDataClassWrapperFile;
    import std.datetime.systime : Clock;
    import std.file : exists, mkdirRecurse, remove, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    const token = randomUUID().toString();
    const root = buildPath(tempDir(), "json-path-save-" ~ token);
    const catalogPath = buildPath(tempDir(), "json-path-save-" ~ token
        ~ ".json");
    mkdirRecurse(root);
    scope (exit)
    {
        if (exists(root))
            rmdirRecurse(root);
        if (exists(catalogPath))
            remove(catalogPath);
    }

    auto blob = new NamedBinaryBlob();
    blob.fileSize = 1;
    blob.fileSpecs = [
        new FileSpec(buildPath(root, "inside.txt"), ""),
        new FileSpec("/etc/hosts", ""),
    ];
    NamedBinaryBlobCatalog catalog = NamedBinaryBlobCatalog(DATA_CLASS_VERSION5,
        [blob]);
    serializeDataClassWrapperFile(catalogPath, catalog);

    auto backend = new JsonCatalogBackend(
        OperationTarget.jsonTarget(catalogPath, root));
    scope (exit)
        backend.close();
    auto document = backend.document();
    AnalysisOperationRequest request;
    request.operationId = 1;
    request.target = backend.target();
    assert(document.applyAnalysis(request, new OperationControl()).state
        == OperationState.completed);
    document.save();

    const loaded = deserializeDataClassJsonWrapperFile(catalogPath);
    assert(loaded.dataArray.length == 1);
    assert(loaded.dataArray[0].fileSpecs.length == 1);
    assert(loaded.dataArray[0].fileSpecs[0].fileName == "inside.txt",
        loaded.dataArray[0].fileSpecs[0].fileName);
}

@("JSON documents suggest and bind a filesystem root for tree queries")
unittest
{
    import dosierskanilo.model.namedbinaryblob : NamedBinaryBlobCatalog,
        serializeDataClassWrapperFile;
    import std.datetime.systime : Clock;
    import std.file : exists, remove, tempDir;
    import std.path : buildPath, dirName;
    import std.uuid : randomUUID;

    const catalogPath = buildPath(tempDir(), "json-root-" ~ randomUUID().toString()
        ~ ".json");
    scope (exit)
        if (exists(catalogPath))
            remove(catalogPath);
    auto blob = new NamedBinaryBlob("media/first.txt", 5, Clock.currTime);
    blob.fileSpecs ~= new FileSpec("media/first.txt", "");
    NamedBinaryBlobCatalog catalog = NamedBinaryBlobCatalog(DATA_CLASS_VERSION5,
        [blob]);
    serializeDataClassWrapperFile(catalogPath, catalog);

    auto backend = new JsonCatalogBackend(
        OperationTarget.jsonTarget(catalogPath));
    scope (exit)
        backend.close();
    auto document = backend.document();
    assert(!backend.capabilities().supportsTreeQueries,
        "unrooted JSON documents defer the tree index until a root is bound");
    const root = document.suggestedFilesystemRoot();
    assert(root == dirName(catalogPath));
    document.bindFilesystemRoot(root);
    assert(backend.capabilities().supportsTreeQueries);
    const directories = backend.listDirectories(CatalogDirectoryQuery.init);
    assert(directories.directories.length == 1);
    assert(directories.directories[0].relativePath == "media");
    document.bindFilesystemRoot("");
    assert(!backend.capabilities().supportsTreeQueries);
}

@("JSON catalog status reports aggregate counters")
unittest
{
    import dosierskanilo.metadata.mediainfosig : MediaInfoAudio, MediaInfoSig;
    import dosierskanilo.metadata.torrentinfo : TorrentInfo;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    const root = buildPath(tempDir(), "json-status-" ~ randomUUID().toString());
    mkdirRecurse(buildPath(root, "sub"));
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);
    write(buildPath(root, "a.txt"), "alpha");
    write(buildPath(root, "sub", "b.txt"), "beta");

    auto rich = new NamedBinaryBlob(
        [new FileSpec("a.txt", "")], 5);
    rich.checkSums.set_md5sum([1]);
    rich.checkSums.set_sha1sum([2]);
    rich.checkSums.set_xxh64([3]);
    rich.fileType = "ASCII text";
    rich.mediaInfoSig = new MediaInfoSig([], [],
        [new MediaInfoAudio(1, "de", "AAC", 6, 200_000, "1h")], []);
    rich.archiveIndexKnown = true;
    rich.torrentInfo = new TorrentInfo();
    rich.torrentInfo.name = "sample";
    rich.torrentInfo.magnetURI = "magnet:?xt=urn:btih:0000";
    rich.torrentInfo.totalSize = 5;
    auto plain = new NamedBinaryBlob(
        [new FileSpec("sub/b.txt", "")], 4);

    const catalogPath = buildPath(root, "catalog.json");
    auto catalog = NamedBinaryBlobCatalog(DATA_CLASS_VERSION5, [rich, plain]);
    serializeDataClassWrapperFile(catalogPath, catalog);

    auto backend = new JsonCatalogBackend(
        OperationTarget.jsonTarget(catalogPath, root));
    scope (exit)
        backend.close();
    const status = backend.catalogStatus();
    assert(status.storageMode == OperationStorageMode.jsonCatalog);
    assert(status.sourcePath == catalogPath);
    assert(status.databasePath.length == 0);
    assert(status.schemaVersion == DATA_CLASS_VERSION5);
    assert(status.blobCount == 2);
    assert(status.referenceCount == 2);
    assert(status.physicalReferenceCount == 2);
    assert(status.archiveMemberCount == 0);
    assert(status.directoryCount == 1);
    assert(status.aggregateSize == 9);
    assert(status.missingReferenceCount == 0);
    assert(status.checksumBlobCount == 1);
    assert(status.fileTypeBlobCount == 1);
    assert(status.mediaBlobCount == 1);
    assert(status.archiveBlobCount == 1);
    assert(status.torrentBlobCount == 1);
    assert(status.duplicateGroupCount == 0);
    assert(status.catalogSize > 0);
    assert(status.treeStatisticsAvailable);
}

@("JSON catalog status reports a load error")
unittest
{
    import std.file : remove, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    const catalogPath = buildPath(tempDir(), "json-status-error-"
        ~ randomUUID().toString() ~ ".json");
    write(catalogPath, "not a catalog");
    scope (exit)
        if (exists(catalogPath))
            remove(catalogPath);

    auto backend = new JsonCatalogBackend(
        OperationTarget.jsonTarget(catalogPath));
    scope (exit)
        backend.close();
    const status = backend.catalogStatus();
    assert(status.error.length > 0);
    assert(status.blobCount == 0);
    assert(!status.treeStatisticsAvailable);
}

@("JSON catalog tolerates null media stream entries")
unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    const root = buildPath(tempDir(), "json-null-media-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);
    write(buildPath(root, "a.txt"), "payload");
    const catalogPath = buildPath(root, "catalog.json");
    write(catalogPath, "{\"dataVersion\":5,\"dataArray\":[{"
        ~ "\"fileSize\":7,\"fileSpecs\":[{\"fileName\":\"a.txt\"}],"
        ~ "\"mediaInfoSig\":{\"imageStreams\":[],\"videoStreams\":[],"
        ~ "\"audioStreams\":[null],\"textStreams\":[]}}]}");

    auto backend = new JsonCatalogBackend(
        OperationTarget.jsonTarget(catalogPath, root));
    scope (exit)
        backend.close();
    const page = backend.listFiles(CatalogFileQuery.init);
    assert(page.files.length == 1);
    assert(!page.files[0].hasMedia);
    assert(!page.files[0].hasAudio);
    const status = backend.catalogStatus();
    assert(status.blobCount == 1);
}

@("JSON empty detail pages reject a zero limit")
unittest
{
    import dosierskanilo.model.filespec : FileSpec;
    import dosierskanilo.model.namedbinaryblob : NamedBinaryBlobCatalog,
        serializeDataClassWrapperFile;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    const root = buildPath(tempDir(), "json-zero-page-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);
    write(buildPath(root, "a.txt"), "payload");
    const catalogPath = buildPath(root, "catalog.json");
    NamedBinaryBlobCatalog catalog = NamedBinaryBlobCatalog(DATA_CLASS_VERSION5,
        [new NamedBinaryBlob([new FileSpec("a.txt", "")], 7)]);
    serializeDataClassWrapperFile(catalogPath, catalog);
    auto backend = new JsonCatalogBackend(
        OperationTarget.jsonTarget(catalogPath, root));
    scope (exit)
        backend.close();
    const contentId = backend.listFiles(CatalogFileQuery.init).files[0].contentId;
    CatalogPageRequest zero;
    zero.limit = 0;
    bool archiveRejected;
    try
        backend.listArchiveEntries(contentId, zero);
    catch (CatalogBackendException failure)
        archiveRejected = failure.code == CatalogBackendErrorCode.invalidCursor;
    assert(archiveRejected);
    bool torrentRejected;
    try
        backend.listTorrentEntries(contentId, zero);
    catch (CatalogBackendException failure)
        torrentRejected = failure.code == CatalogBackendErrorCode.invalidCursor;
    assert(torrentRejected);
}
