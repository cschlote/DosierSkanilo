/** ZIP archive implementation.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, Released under CC-BY-NC-SA 4.0 license, 2018
 * License: CC-BY-NC-SA 4.0
 */
module dosierarkivo.ziparchive;

import std.algorithm : filter, map;
import std.array : array;
import std.file : exists, getcwd, remove;
import std.path : buildPath;
import std.process : execute, executeShell;
import std.regex : matchFirst;
import std.stdio : stderr, write;
import std.string : empty, format, splitLines, startsWith, strip;

import dosierarkivo.archive;
version (unittest)
{
    import dosierarkivo.factory : fileArchive;
    import dosierarkivo.testsupport;
}

/** Implementation for zip files.
 *
 * We use the unzip utility to get the list of entries and to extract files. The unzip utility is available
 * on most systems and supports a wide range of zip formats. The output of the unzip utility is parsed to
 * get the list of entries and to extract files.
 */
class FileArchiveZip : FileArchive
{
    private string[] parseUnzipLongListOutput(string output) const
    {
        string[] entries;
        bool inEntrySection = false;

        foreach (line; output.splitLines)
        {
            auto trimmed = line.strip;
            if (trimmed.empty)
                continue;

            if (!inEntrySection)
            {
                if (trimmed.startsWith("---------"))
                    inEntrySection = true;
                continue;
            }

            if (trimmed.startsWith("---------"))
                break;

            auto m = matchFirst(line, `^\s*\d+\s+\S+\s+\S+\s+(.+?)\s*$`);
            if (m.empty)
                continue;

            auto entryName = m.captures[1].strip;
            if (!entryName.empty)
                entries ~= entryName;
        }

        return entries;
    }

    this(string filename)
    {
        super(ArchiveType.zip, filename);
    }

    override string[] getEntries()
    {
        auto rcMachineReadable = execute(["unzip", "-Z1", this.fileName]);
        if (rcMachineReadable.status == 0)
        {
            return rcMachineReadable.output
                .splitLines
                .map!(line => line.strip)
                .filter!(line => !line.empty)
                .array;
        }

        stderr.writeln("WARNING: unzip -Z1 failed for '", this.fileName,
            "'. Falling back to parsing unzip -l output.");

        auto rcLongList = execute(["unzip", "-l", this.fileName]);
        if (rcLongList.status != 0)
        {
            stderr.writeln("WARNING: unzip -l failed for '", this.fileName,
                "'. Skipping archive entry scan.");
            return [];
        }

        auto entries = parseUnzipLongListOutput(rcLongList.output);
        if (entries.empty)
        {
            stderr.writeln("WARNING: Could not parse unzip -l output for '", this.fileName,
                "'. Skipping archive entry scan.");
        }
        return entries;
    }

    override bool extractEntry(string filename, string destDir)
    {
        auto zipPath = buildPath(getcwd(), this.fileName);
        auto rc = execute(["unzip", "-d", destDir, zipPath, filename]);
        assert(rc.status == 0, rc.output);
        return true;
    }

    version (unittest)
    {
        enum string fn = zipFileName;

        static void createTestArchive()
        {
            if (fn.exists)
                remove(fn);
            auto rc = executeShell("zip -q \"%s\" test/*".format(zipFileName));
            write(rc.output);
            assert(rc.status == 0, rc.output);
        }

        static void deleteTestArchive()
        {
            if (fn.exists)
                remove(fn);
        }
    }
}

@("class FileArchiveZip")
unittest
{
    FileArchiveZip.createTestArchive;
    scope (exit)
        FileArchiveZip.deleteTestArchive;

    auto obj = fileArchive(zipFileName);
    testAbstractImpl(obj);
}

@("zip list parser tolerates output drift")
unittest
{
    auto obj = new FileArchiveZip("dummy.zip");
    auto parsed = obj.parseUnzipLongListOutput("unexpected output\nwithout expected columns\n");
    assert(parsed.length == 0);
}

@("zip archive missing file fallback")
unittest
{
    auto obj = new FileArchiveZip("definitely-missing-archive.zip");
    auto entries = obj.getEntries();
    assert(entries.length == 0);
}

@("archive extraction with special filenames")
unittest
{
    import std.algorithm.searching : countUntil;
    import std.conv : to;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.process : execute, thisProcessID;

    auto tmpRoot = buildPath(tempDir, "dosierskanilo-archive-safe-" ~ thisProcessID.to!string);
    if (tmpRoot.exists)
        rmdirRecurse(tmpRoot);
    mkdirRecurse(tmpRoot);
    scope (exit)
        if (tmpRoot.exists)
            rmdirRecurse(tmpRoot);

    auto specialEntryName = "special 'quoted' ;$ file.txt";
    auto specialSourceFile = buildPath(tmpRoot, specialEntryName);
    write(specialSourceFile, "archive safety regression test\n");

    auto zipArchiveName = "special ;$ 'archive'.zip";
    auto zipArchivePath = buildPath(tmpRoot, zipArchiveName);
    auto zipCreate = execute(["zip", "-q", "-j", zipArchivePath, specialSourceFile]);
    assert(zipCreate.status == 0, zipCreate.output);

    auto zipObj = fileArchive(zipArchivePath);
    assert(zipObj !is null);
    auto zipEntries = zipObj.getEntries();
    assert(zipEntries.countUntil(specialEntryName) >= 0, zipEntries.to!string);

    auto zipExtractDir = buildPath(tmpRoot, "extract zip ;$ dir");
    mkdirRecurse(zipExtractDir);
    assert(zipObj.extractEntry(specialEntryName, zipExtractDir));
    assert(buildPath(zipExtractDir, specialEntryName).exists);
}
