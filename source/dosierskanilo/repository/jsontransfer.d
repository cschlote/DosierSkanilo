/** Repository JSON transfer: import and export of catalog documents.
 *
 * Imports replace or merge catalog records; exports can select a virtual
 * path subset. Cancellation publishes nothing.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo.repository.jsontransfer;

import d2sqlite3;
import std.array : array;
import std.datetime.systime : Clock;
import std.conv : to;
import std.file : exists, mkdirRecurse, remove;
import std.path : buildPath;
import std.string : empty, replace, startsWith;
import dosierskanilo.model.namedbinaryblob : NamedBinaryBlob;
import dosierskanilo.operations : OperationControl;
import dosierskanilo.operationlease : TargetWriteLease;
import dosierskanilo.repository.errors;
import dosierskanilo.repository.transfer : exportCatalogJsonControlled,
    importCatalogJsonControlled, loadCatalogFromDatabase;
import dosierskanilo.repository.types;
import dosierskanilo.repository.repository : Repository;

/** Members of `Repository` in the jsontransfer area; mixed into the class. */
mixin template RepositoryTransfer()
{
    /** Replace the repository catalog with data from a JSON file.
     *
     * Params:
     *     jsonFile = JSON catalog file to import.
     *     options = Import behavior, including force and backup flags.
     */
    void importJson(string jsonFile, JsonImportOptions options = JsonImportOptions())
    {
        importJsonControlled(jsonFile, options, null, 0);
    }

    /**
     * Replace the repository catalog with cooperative cancellation.
     *
     * Params:
     *     jsonFile = JSON catalog file to import.
     *     options = Import behavior, including force and backup flags.
     *     control = Operation control for progress and cancellation, or null.
     *     operationId = ID included in reported progress events.
     * Returns: `true` when the import committed, or `false` when cancelled
     *     before commit; the previous catalog is unchanged when cancelled.
     */
    bool importJsonControlled(string jsonFile, JsonImportOptions options,
        OperationControl control, ulong operationId)
    {
        requireOpen();
        if (control !is null && control.cancellationRequested)
            return false;
        auto targetLease = TargetWriteLease.acquireRepositoryRoot(
            repositoryPaths.rootPath);
        scope (exit)
            targetLease.release();
        if (blobCount > 0)
        {
            if (!options.force)
                throw new RepositoryException(
                    "Repository is not empty. Use force to replace its catalog.");
            if (options.backupExisting)
                backupDatabase();
        }
        if (control !is null && control.cancellationRequested)
            return false;
        return importCatalogJsonControlled(database, repositoryPaths.rootPath,
            jsonFile, options, control, operationId);
    }

    /** Export repository data to a JSON file.
     *
     * Params:
     *     jsonFile = Destination JSON catalog file.
     *     options = Export formatting and selection options.
     */
    void exportJson(string jsonFile, JsonExportOptions options = JsonExportOptions())
    {
        exportJsonControlled(jsonFile, options, null, 0);
    }

    /** Export repository data with cooperative cancellation.
     *
     * Params:
     *     jsonFile = Destination JSON catalog file.
     *     options = Export formatting and selection options.
     *     control = Operation control for progress and cancellation, or null.
     *     operationId = ID included in reported progress events.
     * Returns: `true` when the export completed, or `false` when cancelled.
     */
    bool exportJsonControlled(string jsonFile, JsonExportOptions options,
        OperationControl control, ulong operationId)
    {
        requireOpen();
        if (control !is null && control.cancellationRequested)
            return false;
        auto targetLease = TargetWriteLease.acquireRepositoryRoot(
            repositoryPaths.rootPath);
        scope (exit)
            targetLease.release();
        return exportCatalogJsonControlled(database, repositoryPaths.rootPath,
            jsonFile, options, control, operationId);
    }

    /** Load repository blobs using the shared domain model for consumers.
     *
     * Params:
     *     options = Options controlling which related data is loaded.
     * Returns: All catalog blobs; empty when the repository has no blobs.
     */
    NamedBinaryBlob[] loadCatalog(JsonExportOptions options = JsonExportOptions())
    {
        requireOpen();
        return loadCatalogFromDatabase(database, repositoryPaths.rootPath, options);
    }
}

@("repository import cancellation keeps the previous catalog")
unittest
{
    import std.datetime.systime : Clock;
    import std.file : remove, rmdirRecurse, tempDir;
    import dosierskanilo.operations : OperationKind, OperationProgress;
    import std.uuid : randomUUID;
    import dosierskanilo.model.namedbinaryblob : DATA_CLASS_VERSION5,
        NamedBinaryBlobCatalog, serializeDataClassWrapperFile;

    auto root = buildPath(tempDir(), "repository-import-cancel-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
    {
        if (exists(root))
            rmdirRecurse(root);
    }

    auto repository = Repository.initialize(root);
    scope (exit)
        repository.close();

    auto smallPath = buildPath(root, "small.json");
    NamedBinaryBlobCatalog small;
    small.dataVersion = DATA_CLASS_VERSION5;
    small.dataArray = [new NamedBinaryBlob("keep.txt", 1, Clock.currTime())];
    serializeDataClassWrapperFile(smallPath, small);
    repository.importJson(smallPath);
    assert(repository.blobCount == 1);

    auto largePath = buildPath(root, "large.json");
    NamedBinaryBlobCatalog large;
    large.dataVersion = DATA_CLASS_VERSION5;
    foreach (index; 0 .. 600)
        large.dataArray ~= new NamedBinaryBlob(
            "drop" ~ index.to!string, 1, Clock.currTime());
    serializeDataClassWrapperFile(largePath, large);

    OperationControl control;
    control = new OperationControl((OperationProgress event) {
        if (event.operation == OperationKind.catalogImport
            && event.completed > 0)
            control.requestCancellation();
    });
    JsonImportOptions options;
    options.force = true;
    assert(!repository.importJsonControlled(largePath, options, control, 6));
    assert(repository.blobCount == 1,
        "Cancelled import must roll back the replacement catalog.");
    assert(repository.info.updatedAt.length > 0);
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

@("repository imports legacy array and version-1/version-3 fixtures")
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
    size_t[] expectedCounts = [3, 3, 3, 2, 1];
    JsonImportOptions importOptions;
    importOptions.force = true;
    foreach (index, fixture; fixtures)
    {
        repository.importJson(fixture, importOptions);
        assert(repository.blobCount == expectedCounts[index]);
    }
    repository.close();
}

@("repository imports a version-2 wrapper and exports JSON v5 virtual members")
unittest
{
    import dosierskanilo.model.namedbinaryblob : DATA_CLASS_VERSION5,
        NamedBinaryBlob, deserializeDataClassJsonWrapperFile;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto fixture = buildPath(tempDir(), "repository-json-v2-roundtrip-"
        ~ randomUUID().toString());
    auto root = buildPath(fixture, "repository");
    auto exported = buildPath(fixture, "exported-v5.json");
    mkdirRecurse(root);
    scope (exit)
    {
        if (exists(fixture))
            rmdirRecurse(fixture);
    }

    auto input = deserializeDataClassJsonWrapperFile(
        "./test/json_file_wrapper_v2.json");
    assert(input.dataVersion == 2);
    assert(input.dataArray.length == 1);

    auto repository = Repository.initialize(root);
    scope (exit)
        repository.close();
    repository.importJson("./test/json_file_wrapper_v2.json");

    auto imported = repository.loadCatalog();
    assert(imported.length == 2);
    NamedBinaryBlob blob;
    bool foundMember;
    foreach (record; imported)
        foreach (spec; record.fileSpecs)
        {
            if (spec.fileName == "v2/sample.rar")
                blob = record;
            if (spec.fileName == "v2/sample.rar!/payload.bin")
            {
                foundMember = true;
                assert(record.checkSums.sha1sum_b64
                    == "K8ByyTS7PbXAvLXGiMJ9LnR+UF4=");
            }
        }
    assert(blob !is null && foundMember);
    assert(blob.fileSize == 4096);
    assert(blob.getFirstFileName == "v2/sample.rar");
    assert(blob.checkSums.md5sum_b64 == "CJDSa/B3y0CdbYM+kidLhg==");
    assert(blob.checkSums.sha1sum_b64 == "K8ByyTS7PbXAvLXGiMJ9LnR+UF4=");
    assert(blob.fileType == "RAR archive data");
    assert(blob.archiveIndexKnown);

    repository.exportJson(exported);
    auto roundtrip = deserializeDataClassJsonWrapperFile(exported);
    assert(roundtrip.dataVersion == DATA_CLASS_VERSION5);
    assert(roundtrip.dataArray.length == 2);
    bool foundContainer;
    bool roundtripMember;
    foreach (record; roundtrip.dataArray)
        foreach (spec; record.fileSpecs)
        {
            foundContainer = foundContainer
                || spec.fileName == "v2/sample.rar";
            roundtripMember = roundtripMember
                || spec.fileName == "v2/sample.rar!/payload.bin";
        }
    assert(foundContainer && roundtripMember);
}

@("filtered JSON export preserves selected blob relationship closure")
unittest
{
    import std.algorithm.searching : startsWith;
    import dosierskanilo.model.namedbinaryblob : DATA_CLASS_VERSION5,
        deserializeDataClassJsonWrapperFile;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto fixture = buildPath(tempDir(), "repository-filtered-export-closure-"
        ~ randomUUID().toString());
    auto root = buildPath(fixture, "source");
    auto roundtripRoot = buildPath(fixture, "roundtrip");
    auto exported = buildPath(fixture, "selected-export.json");
    mkdirRecurse(buildPath(root, "wanted"));
    mkdirRecurse(buildPath(root, "excluded"));
    mkdirRecurse(roundtripRoot);
    scope (exit)
    {
        if (exists(fixture))
            rmdirRecurse(fixture);
    }

    write(buildPath(root, "wanted", "selected-one.bin"), "same selected content");
    write(buildPath(root, "wanted", "selected-two.bin"), "same selected content");
    write(buildPath(root, "excluded", "shared-outside.bin"), "same selected content");
    write(buildPath(root, "excluded", "outside-only.bin"), "not selected");

    auto repository = Repository.initialize(root);
    scope (exit)
        repository.close();
    repository.scan();
    MetadataScanOptions metadataOptions;
    metadataOptions.calculateChecksums = true;
    repository.updateMetadata(metadataOptions);
    auto analysis = repository.analyze();
    assert(analysis.duplicateGroups == 1);
    assert(analysis.mergedBlobs == 2);
    assert(repository.blobCount == 2);

    JsonExportOptions exportOptions;
    exportOptions.pathPrefix = "wanted";
    repository.exportJson(exported, exportOptions);

    auto exportedCatalog = deserializeDataClassJsonWrapperFile(exported);
    assert(exportedCatalog.dataVersion == DATA_CLASS_VERSION5);
    assert(exportedCatalog.dataArray.length == 1,
        "only the blob referenced by the selected paths should be exported");
    auto selectedBlob = exportedCatalog.dataArray[0];
    assert(selectedBlob.fileSpecs.length == 2);
    assert(selectedBlob.checkSums.hasDigests);
    bool sawFirst;
    bool sawSecond;
    foreach (spec; selectedBlob.fileSpecs)
    {
        assert(spec !is null);
        assert(spec.fileName.startsWith("wanted/"));
        sawFirst = sawFirst || spec.fileName == "wanted/selected-one.bin";
        sawSecond = sawSecond || spec.fileName == "wanted/selected-two.bin";
    }
    assert(sawFirst && sawSecond);

    auto roundtrip = Repository.initialize(roundtripRoot);
    scope (exit)
        roundtrip.close();
    roundtrip.importJson(exported);
    auto imported = roundtrip.loadCatalog();
    assert(imported.length == 1);
    assert(imported[0].fileSpecs.length == 2);
    assert(imported[0].checkSums.hasDigests);
    foreach (spec; imported[0].fileSpecs)
        assert(spec.fileName.startsWith("wanted/"));
}
