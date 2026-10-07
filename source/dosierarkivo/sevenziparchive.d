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
        auto rc = execute(["7z", "x", passwordOption, tarPath, filename,
            "-o" ~ destDir]);
        if (rc.status != 0 && isArchivePasswordFailure(rc.output))
            throw new ArchivePasswordRequiredException(rc.output);
        assert(rc.status == 0, rc.output);
        return true;
    }

    version (unittest)
    {
        enum string fn = _7zFileName;

        static void createTestArchive()
        {
            deleteTestArchive;
            auto cmd = "7z a \"%s\" test/*".format(_7zFileName);
            auto rc = executeShell(cmd);
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
