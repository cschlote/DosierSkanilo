/** TAR archive implementation.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierarkivo.tararchive;

import std.algorithm : filter;
import std.algorithm.searching : canFind;
import std.array : array;
import std.conv : to;
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

/** TAR archive adapter backed by the `tar` command-line tool. */
class FileArchiveTar : FileArchive
{
    /** Create a wrapper for one TAR file.
     *
     * Params:
     *     filename = Path to the TAR archive on disk; stored unchanged.
     */
    this(string filename)
    {
        super(ArchiveType.tar, filename);
    }

    /** List member names using `tar -tf`.
     *
     * Params:
     *     password = Accepted for interface compatibility; TAR listing does not
     *         use it.
     * Returns: Member names in archive order; empty lines are dropped.
     * Throws: `ArchiveToolException` when `tar` exits unsuccessfully.
     */
    override string[] getEntries(string password = "")
    {
        auto rc = execute(["tar", "-tf", this.fileName]);
        if (rc.status != 0)
            throw new ArchiveToolException(rc.output);
        return rc.output.split("\n").filter!(a => !a.empty).array;
    }

    /** Extract one member into `destDir` using `tar`.
     *
     * Params:
     *     filename = Member name exactly as reported by the archive listing.
     *     destDir = Directory that receives the extracted member.
     *     password = Accepted for interface compatibility; TAR extraction does
     *         not use it.
     * Returns: `true` on success.
     * Throws: `ArchiveToolException` when `tar` exits unsuccessfully.
     */
    override bool extractEntry(string filename, string destDir, string password = "")
    {
        auto tarPath = buildPath(getcwd(), this.fileName);
        auto rc = execute(["tar", "-xf", tarPath, "-C", destDir, "--", filename]);
        if (rc.status != 0)
            throw new ArchiveToolException(rc.output);
        return true;
    }

    /** Report whether the local `tar` supports `--occurrence`.
     *
     * Returns: `true` when `tar --help` advertises the occurrence option.
     */
    override @property bool supportsEntryOccurrence() const
    {
        return executeShell("tar --help").output.canFind("--occurrence");
    }

    /** Extract the exact occurrence identified by a descriptor.
     *
     * Unique names are delegated to the name-based overload; duplicates are
     * selected with `--occurrence=<n>` where `<n>` is one-based.
     *
     * Params:
     *     descriptor = Entry identity returned by `getEntryDescriptors`.
     *     destDir = Directory that receives the extracted member.
     *     password = Accepted for interface compatibility; TAR extraction does
     *         not use it.
     * Returns: `true` on success, `false` when duplicate selection is needed
     *     but the local `tar` lacks `--occurrence`.
     */
    override bool extractEntry(ArchiveEntryDescriptor descriptor, string destDir,
        string password = "")
    {
        if (!descriptor.hasDuplicateName)
            return extractEntry(descriptor.name, destDir, password);
        if (!supportsEntryOccurrence)
            return false;
        const auto tarPath = buildPath(getcwd(), this.fileName);
        const auto occurrenceOption = "--occurrence="
            ~ (descriptor.occurrence + 1).to!string;
        const auto rc = execute(["tar", "--extract", "--file=" ~ tarPath,
            "--directory=" ~ destDir, occurrenceOption, "--", descriptor.name]);
        return rc.status == 0;
    }

    version (unittest)
    {
        /** Test archive file name produced by the unittest fixture. */
        enum string fn = tarFileName;

        /** Build the TAR fixture from `expectedEntries`, replacing any old file. */
        static void createTestArchive()
        {
            deleteTestArchive;
            auto rc = execute(["tar", "-cf", tarFileName] ~ expectedEntries);
            write(rc.output);
            assert(rc.status == 0, rc.output);
        }

        /** Remove the TAR fixture if it exists. */
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

@("tar duplicate occurrence extraction selects exact content")
unittest
{
    import std.file : exists, mkdirRecurse, readText, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.process : execute;
    import std.uuid : randomUUID;

    const auto root = buildPath(tempDir(), "tar-duplicate-occurrence-"
        ~ randomUUID().toString());
    const auto firstSource = buildPath(root, "source-first");
    const auto secondSource = buildPath(root, "source-second");
    const auto archivePath = buildPath(root, "duplicate.tar");
    const auto firstOutput = buildPath(root, "output-first");
    const auto secondOutput = buildPath(root, "output-second");
    mkdirRecurse(firstSource);
    mkdirRecurse(secondSource);
    mkdirRecurse(firstOutput);
    mkdirRecurse(secondOutput);
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);
    write(buildPath(firstSource, "same.txt"), "first occurrence");
    write(buildPath(secondSource, "same.txt"), "second occurrence");
    const auto created = execute(["tar", "-cf", archivePath, "-C", firstSource,
        "same.txt", "-C", secondSource, "same.txt"]);
    assert(created.status == 0, created.output);

    auto archive = new FileArchiveTar(archivePath);
    assert(archive.supportsEntryOccurrence);
    auto entries = archive.getEntryDescriptors();
    assert(entries.length == 2);
    assert(entries[0].hasDuplicateName && entries[1].hasDuplicateName);
    assert(entries[0].occurrence == 0 && entries[1].occurrence == 1);
    assert(archive.extractEntry(entries[0], firstOutput));
    assert(archive.extractEntry(entries[1], secondOutput));
    assert(readText(buildPath(firstOutput, "same.txt")) == "first occurrence");
    assert(readText(buildPath(secondOutput, "same.txt")) == "second occurrence");
}


@("tar extraction does not interpret member names as options")
unittest
{
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath, dirName;
    import std.process : execute;
    import std.uuid : randomUUID;

    const auto root = buildPath(tempDir(), "tar-member-injection-"
        ~ randomUUID().toString());
    const auto source = buildPath(root, "source");
    const auto output = buildPath(root, "output");
    const auto archivePath = buildPath(root, "evil.tar");
    const auto marker = buildPath(root, "pwned");
    const auto member = "--to-command=touch " ~ marker;
    mkdirRecurse(source);
    mkdirRecurse(output);
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);

    const auto memberPath = buildPath(source, member);
    mkdirRecurse(dirName(memberPath));
    write(memberPath, "payload");
    auto created = execute(["tar", "-cf", archivePath, "-C", source, "--",
        member]);
    assert(created.status == 0, created.output);

    auto archive = new FileArchiveTar(archivePath);
    assert(archive.extractEntry(member, output));
    assert(!exists(marker), "tar executed a member name as an option");
}
