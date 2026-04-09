/** 7z archive implementation.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, Released under CC-BY-NC-SA 4.0 license, 2018
 * License: CC-BY-NC-SA 4.0
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

    override string[] getEntries()
    {
        auto rc0 = execute(["7z", "l", "-p", "-ba", this.fileName]);
        if (rc0.status == 2)
            return null;

        auto rc = execute(["7z", "l", "-ba", this.fileName]);
        assert(rc.status == 0, rc.output);

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

    override bool extractEntry(string filename, string destDir)
    {
        auto tarPath = buildPath(getcwd(), this.fileName);
        auto rc = execute(["7z", "x", tarPath, filename, "-o" ~ destDir]);
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
