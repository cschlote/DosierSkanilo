/** 7z archive implementation.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierarkivo.sevenziparchive;

import std.file : exists, getcwd, remove;
import std.path : buildPath;
import std.process : execute, executeShell;
import std.regex : matchFirst;
import std.string : empty, format, splitLines, strip;

import dosierarkivo.archive;
version (unittest)
{
    import dosierarkivo.factory : fileArchive;
    import dosierarkivo.testsupport;
}

class FileArchive7z : FileArchive
{
    this(string filename)
    {
        super(ArchiveType._7z, filename);
    }

    override string[] getEntries(string password = "")
    {
        auto passwordOption = password.length > 0
            ? "-p" ~ password : "-p__dosierskanilo_no_password__";
        auto rc = execute(["7z", "l", passwordOption, "-ba", this.fileName]);
        if (rc.status != 0 && isArchivePasswordFailure(rc.output))
            throw new ArchivePasswordRequiredException(rc.output);
        if (rc.status != 0)
            return [];

        string[] entries;
        auto lines = rc.output.splitLines;
        foreach (line; lines)
        {
            auto m = matchFirst(line,
                `^(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2}:\d{2})\s+(\S+)\s+(\d+)\s+(\d*)\s+(.+)$`);
            if (m.empty)
                continue;

            auto attrs = m.captures[3];
            if (attrs.length > 0 && attrs[0] == 'D')
                continue;

            auto entryName = m.captures[6].strip;
            if (!entryName.empty)
                entries ~= entryName;
        }
        return entries;
    }

    override bool extractEntry(string filename, string destDir, string password = "")
    {
        auto tarPath = buildPath(getcwd(), this.fileName);
        auto passwordOption = password.length > 0
            ? "-p" ~ password : "-p__dosierskanilo_no_password__";
        auto rc = execute(["7z", "x", passwordOption, "-o" ~ destDir, tarPath,
            "--", filename]);
        if (rc.status != 0 && isArchivePasswordFailure(rc.output))
            throw new ArchivePasswordRequiredException(rc.output);
        if (rc.status != 0)
            throw new ArchiveToolException(rc.output);
        return true;
    }

    version (unittest)
    {
        enum string fn = _7zFileName;

        static void createTestArchive()
        {
            deleteTestArchive;
            auto rc = execute(["7z", "a", _7zFileName] ~ expectedEntries);
            assert(rc.status == 0, rc.output);
        }

        static void deleteTestArchive()
        {
            if (fn.exists)
                remove(fn);
        }
    }
}

@("class FileArchive7z")
unittest
{
    FileArchive7z.createTestArchive;
    scope (exit)
        FileArchive7z.deleteTestArchive;

    auto obj = fileArchive(_7zFileName);
    testAbstractImpl(obj);
}

@("7z extraction treats option-like member names as files")
unittest
{
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.process : execute, executeShell;
    import std.uuid : randomUUID;

    if (executeShell("command -v 7z").status != 0)
        return;
    const auto root = buildPath(tempDir(), "7z-option-member-"
        ~ randomUUID().toString());
    const auto source = buildPath(root, "source", "-oevil.txt");
    const auto archivePath = buildPath(root, "option.7z");
    const auto output = buildPath(root, "output");
    mkdirRecurse(buildPath(root, "source"));
    mkdirRecurse(output);
    write(source, "payload");
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);

    const auto created = execute(["7z", "a", archivePath, source]);
    assert(created.status == 0, created.output);
    auto archive = new FileArchive7z(archivePath);
    assert(archive.extractEntry("-oevil.txt", output));
    assert(exists(buildPath(output, "-oevil.txt")));
    assert(!exists(buildPath(output, "evil.txt")));
}
