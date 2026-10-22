/** ZIP archive implementation.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierarkivo.ziparchive;

import std.algorithm : filter, map;
import std.array : array;
import std.conv : to;
import std.file : exists, getcwd, remove;
import std.path : buildPath, isAbsolute;
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

    override string[] getEntries(string password = "")
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
        if (isArchivePasswordFailure(rcMachineReadable.output))
            throw new ArchivePasswordRequiredException(rcMachineReadable.output);

        stderr.writeln("WARNING: unzip -Z1 failed for '", this.fileName,
            "'. Falling back to parsing unzip -l output.");

        auto rcLongList = execute(["unzip", "-l", this.fileName]);
        if (rcLongList.status != 0)
        {
            if (isArchivePasswordFailure(rcLongList.output))
                throw new ArchivePasswordRequiredException(rcLongList.output);
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

    override bool extractEntry(string filename, string destDir, string password = "")
    {
        auto zipPath = buildPath(getcwd(), this.fileName);
        auto rc = execute(["unzip", "-P", password, "-d", destDir, zipPath, filename]);
        if (rc.status != 0 && isArchivePasswordFailure(rc.output))
            throw new ArchivePasswordRequiredException(rc.output);
        if (rc.status != 0)
            throw new ArchiveToolException(rc.output);
        return true;
    }

    override @property bool supportsEntryOccurrence() const
    {
        return executeShell("python3 --version").status == 0;
    }

    override bool extractEntry(ArchiveEntryDescriptor descriptor, string destDir,
        string password = "")
    {
        if (!descriptor.hasDuplicateName)
            return extractEntry(descriptor.name, destDir, password);
        if (!supportsEntryOccurrence)
            return false;

        enum extractionScript = "import os, shutil, sys, zipfile\n"
            ~ "archive, index, dest, member, expected, password = sys.argv[1:]\n"
            ~ "with zipfile.ZipFile(archive) as z:\n"
            ~ "    info = z.infolist()[int(index)]\n"
            ~ "    if info.filename != expected:\n"
            ~ "        raise RuntimeError('archive entry index/name mismatch')\n"
            ~ "    os.makedirs(os.path.dirname(os.path.join(dest, member)), exist_ok=True)\n"
            ~ "    with z.open(info, 'r', pwd=password.encode() if password else None) as src:\n"
            ~ "        with open(os.path.join(dest, member), 'wb') as out:\n"
            ~ "            shutil.copyfileobj(src, out)\n";
        auto zipPath = isAbsolute(this.fileName) ? this.fileName
            : buildPath(getcwd(), this.fileName);
        auto rc = execute(["python3", "-c", extractionScript, zipPath,
            descriptor.index.to!string, destDir, descriptor.relativePath,
            descriptor.name, password]);
        if (rc.status != 0 && isArchivePasswordFailure(rc.output))
            throw new ArchivePasswordRequiredException(rc.output);
        return rc.status == 0;
    }

    version (unittest)
    {
        enum string fn = zipFileName;

        static void createTestArchive()
        {
            if (fn.exists)
                remove(fn);
            auto rc = execute(["zip", "-q", zipFileName] ~ expectedEntries);
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

@("zip duplicate occurrence extraction selects exact content")
unittest
{
    import std.file : exists, mkdirRecurse, readText, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.process : execute, executeShell;
    import std.uuid : randomUUID;

    if (executeShell("command -v python3").status != 0)
        return;
    const auto root = buildPath(tempDir(), "zip-duplicate-occurrence-"
        ~ randomUUID().toString());
    const auto archivePath = buildPath(root, "duplicate.zip");
    const auto firstDirectory = buildPath(root, "first");
    const auto secondDirectory = buildPath(root, "second");
    mkdirRecurse(root);
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);

    const auto createScript = "import sys, zipfile; z=zipfile.ZipFile(sys.argv[1], 'w'); "
        ~ "z.writestr('same.txt', 'first occurrence'); "
        ~ "z.writestr('same.txt', 'second occurrence'); z.close()";
    const auto created = execute(["python3", "-c", createScript, archivePath]);
    assert(created.status == 0, created.output);
    auto archive = new FileArchiveZip(archivePath);
    assert(archive.supportsEntryOccurrence);
    auto entries = archive.getEntryDescriptors();
    assert(entries.length == 2);
    assert(entries[0].hasDuplicateName && entries[1].hasDuplicateName);
    assert(entries[0].occurrence == 0 && entries[1].occurrence == 1);
    assert(archive.extractEntry(entries[0], firstDirectory));
    assert(archive.extractEntry(entries[1], secondDirectory));
    assert(readText(buildPath(firstDirectory, "same.txt")) == "first occurrence");
    assert(readText(buildPath(secondDirectory, "same.txt")) == "second occurrence");
}
