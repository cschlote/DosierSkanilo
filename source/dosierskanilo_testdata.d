/** Command-line frontend for the deterministic synthetic test catalog generator. */
module dosierskanilo_testdata;

import std.exception : enforce;
import std.file : mkdirRecurse, write;
import std.getopt : GetoptResult, getopt;
import std.path : buildPath, dirName;
import std.stdio : stderr, writeln;

import dosierskanilo.testdata : generateSyntheticCatalog;

immutable string generatorHelp = q"EOS

Create the deterministic DosierSkanilo synthetic backend/archive test catalog.

Usage:
  dub run --config=synthetic-testdata -- [OPTIONS]

Options:
  --output PATH          Output bundle (default build/test-data/synthetic-catalog)
  --replace              Replace the specified generated bundle
  --update-manifest PATH Write this generated manifest as a reviewed golden
  -h, --help             Show this help

The output bundle contains a `catalog/` tree and a `manifest.json`. It does not
write binary fixtures into the source tree unless --output explicitly points there.

EOS";

int main(string[] args)
{
    string outputPath = buildPath("build", "test-data", "synthetic-catalog");
    string updateManifestPath;
    bool replaceOutput;
    GetoptResult parsed;
    try
    {
        parsed = getopt(args,
            "output", "Output bundle path", &outputPath,
            "replace", "Replace an existing generated bundle", &replaceOutput,
            "update-manifest", "Write/update a reviewed golden manifest", &updateManifestPath);
    }
    catch (Exception error)
    {
        stderr.writeln("Invalid generator arguments: ", error.msg);
        return 2;
    }
    if (parsed.helpWanted)
    {
        writeln(generatorHelp);
        return 0;
    }

    try
    {
        auto fixture = generateSyntheticCatalog(outputPath, replaceOutput,
            updateManifestPath.length > 0);
        if (updateManifestPath.length > 0)
        {
            mkdirRecurse(dirName(updateManifestPath));
            write(updateManifestPath, fixture.manifest.toPrettyString ~ "\n");
        }
        writeln("Synthetic catalog: ", fixture.catalogRoot);
        writeln("Manifest: ", fixture.manifestPath);
        if (updateManifestPath.length > 0)
            writeln("Updated expected manifest: ", updateManifestPath);
        return 0;
    }
    catch (Exception error)
    {
        stderr.writeln("Synthetic catalog generation failed: ", error.msg);
        return 1;
    }
}
