/+ dub.sdl:
name "benchmark-json-members"
dependency "dosierskanilo" path=".."
+/
module benchmark_json_members;

/** Measure JSON archive-member page construction.
 *
 * Run from the repository root:
 *   dub run --single scripts/benchmark-json-members.d --build=release -- \
 *       [member-count]
 */
import std.conv : to;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.datetime.systime : Clock;
import std.file : exists, remove, tempDir;
import std.path : buildPath;
import std.stdio : writeln;
import std.uuid : randomUUID;

import dosierskanilo.catalogbackend;
import dosierskanilo.jsoncatalogbackend;
import dosierskanilo.model.archivespec : ArchiveSpec;
import dosierskanilo.model.checksums : CheckSums;
import dosierskanilo.model.namedbinaryblob : DATA_CLASS_VERSION5,
    NamedBinaryBlob, NamedBinaryBlobCatalog, serializeDataClassWrapperFile;
import dosierskanilo.operations : OperationTarget;

void main(string[] args)
{
    const size_t memberCount = args.length > 1 ? args[1].to!size_t : 100_000;
    const catalogPath = buildPath(tempDir(),
        "benchmark-members-" ~ randomUUID().toString() ~ ".json");
    scope (exit)
        if (exists(catalogPath))
            remove(catalogPath);

    auto container = new NamedBinaryBlob("archive.zip", memberCount * 10,
        Clock.currTime());
    container.archiveSpecs = new ArchiveSpec[0];
    container.archiveSpecs.reserve(memberCount);
    foreach (index; 0 .. memberCount)
        container.archiveSpecs ~= new ArchiveSpec(
            "dir/member" ~ index.to!string ~ ".txt", 1 + index,
            "2020-01-02T04:04:06", CheckSums.init);
    container.archiveIndexKnown = true;
    container.archiveIndexDeep = true;

    NamedBinaryBlobCatalog catalog;
    catalog.dataVersion = DATA_CLASS_VERSION5;
    catalog.dataArray = [container];
    serializeDataClassWrapperFile(catalogPath, catalog);

    auto backend = new JsonCatalogBackend(
        OperationTarget.jsonTarget(catalogPath, tempDir()));
    scope (exit)
        backend.close();

    CatalogFileQuery query;
    query.filter.includeArchiveMembers = true;
    CatalogPageRequest request;
    request.limit = 250;

    auto stopwatch = StopWatch(AutoStart.yes);
    auto page = backend.listFiles(query, request);
    stopwatch.stop();
    writeln("members=", memberCount,
        " first_page_ms=", stopwatch.peek.total!"msecs",
        " files=", page.files.length, " hasMore=", page.hasMore);

    stopwatch.reset();
    stopwatch.start();
    page = backend.nextFilesPage(query, page.nextCursor);
    stopwatch.stop();
    writeln("second_page_ms=", stopwatch.peek.total!"msecs",
        " files=", page.files.length);
}
