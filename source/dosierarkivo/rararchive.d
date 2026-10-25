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
        if (rc.status != 0)
            throw new ArchiveToolException(rc.output);
        return rc.output.split("\n").filter!(a => !a.empty).array;
    }

    override bool extractEntry(string filename, string destDir, string password = "")
    {
        auto tarPath = buildPath(getcwd(), this.fileName);
        auto passwordOption = password.length > 0 ? "-p" ~ password : "-p-";
        auto rc = execute(["unrar", "x", passwordOption, tarPath, "--", filename, destDir]);
        if (rc.status != 0 && isArchivePasswordFailure(rc.output))
            throw new ArchivePasswordRequiredException(rc.output);
        if (rc.status != 0)
            throw new ArchiveToolException(rc.output);
        return true;
    }

    version (unittest)
    {
        enum string fn = rarFileName;

        static void createTestArchive()
        {
            deleteTestArchive;
            auto rc = execute(["rar", "a", rarFileName] ~ expectedEntries);
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

@("rar extraction treats option-like member names as files")
unittest
{
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.process : execute, executeShell;
    import std.uuid : randomUUID;

    if (executeShell("command -v rar").status != 0)
        return;
    const auto root = buildPath(tempDir(), "rar-option-member-"
        ~ randomUUID().toString());
    const auto source = buildPath(root, "source", "-psecret");
    const auto archivePath = buildPath(root, "option.rar");
    const auto output = buildPath(root, "output");
    mkdirRecurse(buildPath(root, "source"));
    mkdirRecurse(output);
    write(source, "payload");
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);

    const auto created = execute(["rar", "a", "-ep", archivePath, source]);
    assert(created.status == 0, created.output);
    auto archive = new FileArchiveRar(archivePath);
    assert(archive.extractEntry("-psecret", output));
    assert(exists(buildPath(output, "-psecret")));
}
