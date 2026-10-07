/** RAR archive implementation.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierarkivo.rararchive;

import std.algorithm : filter;
import std.array : array;
import std.file : exists, getcwd, remove;
import std.path : buildPath;
import std.process : execute, executeShell;
import std.string : empty, format, split;

import dosierarkivo.archive;
version (unittest)
{
    import dosierarkivo.factory : fileArchive;
    import dosierarkivo.testsupport;
}

class FileArchiveRar : FileArchive
{
    this(string filename)
    {
        super(ArchiveType.rar, filename);
    }

    override string[] getEntries(string password = "")
    {
        auto passwordOption = password.length > 0 ? "-p" ~ password : "-p-";
        auto rc = execute(["unrar", "lb", passwordOption, this.fileName]);
        if (rc.status != 0 && isArchivePasswordFailure(rc.output))
            throw new ArchivePasswordRequiredException(rc.output);
        assert(rc.status == 0, rc.output);
        return rc.output.split("\n").filter!(a => !a.empty).array;
    }

    override bool extractEntry(string filename, string destDir, string password = "")
    {
        auto tarPath = buildPath(getcwd(), this.fileName);
        auto passwordOption = password.length > 0 ? "-p" ~ password : "-p-";
        auto rc = execute(["unrar", "x", passwordOption, tarPath, filename, destDir]);
        if (rc.status != 0 && isArchivePasswordFailure(rc.output))
            throw new ArchivePasswordRequiredException(rc.output);
        assert(rc.status == 0, rc.output);
        return true;
    }

    version (unittest)
    {
        enum string fn = rarFileName;

        static void createTestArchive()
        {
            deleteTestArchive;
            auto cmd = "rar a \"%s\" test/*".format(rarFileName);
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

@("class FileArchiveRar")
unittest
{
    if (executeShell("command -v rar").status != 0)
        return;

    FileArchiveRar.createTestArchive;
    scope (exit)
        FileArchiveRar.deleteTestArchive;

    auto obj = fileArchive(rarFileName);
    testAbstractImpl(obj);
}
