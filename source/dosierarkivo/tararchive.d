/** TAR archive implementation.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, Released under CC-BY-NC-SA 4.0 license, 2018
 * License: CC-BY-NC-SA 4.0
 */
module dosierarkivo.tararchive;

import std.algorithm : filter;
import std.array : array;
import std.file : exists, getcwd, remove;
import std.path : buildPath;
import std.process : execute, executeShell;
import std.stdio : write;
import std.string : empty, format, split;

import dosierarkivo.archive;
version (unittest)
{
    import dosierarkivo.factory : fileArchive;
    import dosierarkivo.testsupport;
}

class FileArchiveTar : FileArchive
{
    this(string filename)
    {
        super(ArchiveType.tar, filename);
    }

    override string[] getEntries()
    {
        auto rc = execute(["tar", "-tf", this.fileName]);
        assert(rc.status == 0, rc.output);
        return rc.output.split("\n").filter!(a => !a.empty).array;
    }

    override bool extractEntry(string filename, string destDir)
    {
        auto tarPath = buildPath(getcwd(), this.fileName);
        auto rc = execute(["tar", "-xf", tarPath, "-C", destDir, filename]);
        assert(rc.status == 0, rc.output);
        return true;
    }

    version (unittest)
    {
        enum string fn = tarFileName;

        static void createTestArchive()
        {
            deleteTestArchive;
            auto rc = executeShell("tar -cf \"%s\" test/*".format(tarFileName));
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

@("class FileArchiveTar")
unittest
{
    FileArchiveTar.createTestArchive;
    scope (exit)
        FileArchiveTar.deleteTestArchive;

    auto obj = fileArchive(tarFileName);
    testAbstractImpl(obj);
}
