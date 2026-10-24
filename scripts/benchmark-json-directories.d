/+ dub.sdl:
name "benchmark-json-directories"
dependency "dosierskanilo" path=".."
+/
module benchmark_json_directories;

/** Measure filtered JSON directory projection.
 *
 * Run from the repository root:
 *   dub run --single scripts/benchmark-json-directories.d --build=release -- \
 *       [directory-count] [files-per-directory]
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
import dosierskanilo.model.namedbinaryblob : DATA_CLASS_VERSION5,
    NamedBinaryBlob, NamedBinaryBlobCatalog, serializeDataClassWrapperFile;
import dosierskanilo.operations : OperationTarget;

void main(string[] args)
{
    const size_t directoryCount = args.length > 1 ? args[1].to!size_t : 2_000;
    const size_t filesPerDirectory = args.length > 2 ? args[2].to!size_t : 100;
    const catalogPath = buildPath(tempDir(),
        "benchmark-directories-" ~ randomUUID().toString() ~ ".json");
    scope (exit)
        if (exists(catalogPath))
            remove(catalogPath);

    NamedBinaryBlobCatalog catalog;
    catalog.dataVersion = DATA_CLASS_VERSION5;
    catalog.dataArray.reserve(directoryCount * filesPerDirectory);
    foreach (directory; 0 .. directoryCount)
        foreach (file; 0 .. filesPerDirectory)
            catalog.dataArray ~= new NamedBinaryBlob(
                "dir" ~ directory.to!string ~ "/file" ~ file.to!string ~ ".bin",
                1 + file, Clock.currTime());
    serializeDataClassWrapperFile(catalogPath, catalog);

    auto backend = new JsonCatalogBackend(
        OperationTarget.jsonTarget(catalogPath, tempDir()));
    scope (exit)
        backend.close();

    CatalogDirectoryQuery query;
    query.filter.pathText = "zzz-not-present";
    auto stopwatch = StopWatch(AutoStart.yes);
    auto page = backend.listDirectories(query, CatalogPageRequest(2_000));
    stopwatch.stop();
    writeln("directories=", directoryCount,
        " files_per_directory=", filesPerDirectory,
        " elapsed_ms=", stopwatch.peek.total!"msecs",
        " result=", page.directories.length, " hasMore=", page.hasMore);
}
