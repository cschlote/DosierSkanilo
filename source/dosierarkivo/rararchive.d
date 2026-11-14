/** RAR archive implementation.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierarkivo.rararchive;

import std.algorithm : any, filter;
import std.array : array;
import std.conv : to;
import std.file : exists, getcwd, remove;
import std.path : absolutePath, buildPath;
import std.process : Config, execute, executeShell;
import std.string : empty, format, indexOf, replace, split, splitLines,
    startsWith, strip;

import dosierarkivo.archive;
version (unittest)
{
    import dosierarkivo.factory : fileArchive;
    import dosierarkivo.testsupport;
}

/** RAR archive adapter backed by the `unrar` command-line tool. */
class FileArchiveRar : FileArchive
{
    /** Create a wrapper for one RAR file.
     *
     * Params:
     *     filename = Path to the RAR archive on disk; stored unchanged.
     */
    this(string filename)
    {
        super(ArchiveType.rar, filename);
    }

    /** Like `FileArchive.getEntryDescriptors`, enriched with `unrar lt` metadata.
     *
     * Size, modification time and directory flags are read from the verbose
     * listing. A partial listing is accepted when at least one `Name:` block was
     * parsed, so a truncated archive still yields usable metadata.
     *
     * Params:
     *     password = Archive password; empty disables password prompting.
     * Returns: Descriptors in listing order, or `null` when the base
     *     implementation returns no listing.
     * Throws: `ArchivePasswordRequiredException` when a password is missing or
     *     rejected, `ArchiveToolException` when the listing fails without any
     *     usable entry.
     */
    override ArchiveEntryDescriptor[] getEntryDescriptors(string password = "")
    {
        auto entries = super.getEntryDescriptors(password);
        if (entries is null)
            return null;

        struct Metadata
        {
            ulong size;
            string modifiedAt;
            bool hasSize;
            bool hasModifiedAt;
            bool isDirectory;
        }

        auto passwordOption = password.length > 0 ? "-p" ~ password : "-p-";
        string[string] environment;
        environment["LC_ALL"] = "C";
        auto rc = execute(["unrar", "lt", passwordOption, absolutePath(this.fileName)],
            environment, Config.stderrPassThrough);
        /* unrar exits with 11 for a wrong password even when the diagnostic
         * goes to stderr and stdout is empty. */
        if (isArchivePasswordFailure(rc.output) || rc.status == 11)
            throw new ArchivePasswordRequiredException(rc.output.length > 0
                ? rc.output : password.length > 0
                    ? "incorrect archive password"
                    : "archive password required");
        /* A warning or a truncated archive can still provide a useful partial
         * listing. Accept it when at least one entry was parsed. */
        if (rc.status != 0 && !rc.output.splitLines.any!(line =>
                line.strip.startsWith("Name: ")))
            throw new ArchiveToolException(rc.output.length > 0
                ? rc.output : format("unrar lt failed with exit code %d",
                    rc.status));

        Metadata[string] metadata;
        Metadata current;
        string currentName;
        void commitCurrent()
        {
            if (currentName.length > 0)
                metadata[currentName] = current;
            current = Metadata.init;
            currentName = "";
        }
        foreach (line; rc.output.splitLines())
        {
            const text = line.strip;
            if (text.startsWith("Name: "))
            {
                commitCurrent();
                currentName = text[6 .. $].strip;
            }
            else if (currentName.length > 0 && text.startsWith("Type: "))
                current.isDirectory = text[6 .. $].strip == "Directory";
            else if (currentName.length > 0 && text.startsWith("Size: "))
            {
                try
                {
                    current.size = text[6 .. $].strip.to!ulong;
                    current.hasSize = !current.isDirectory;
                }
                catch (Exception)
                {
                }
            }
            else if (currentName.length > 0 && text.startsWith("mtime: "))
            {
                auto value = text[7 .. $].strip;
                const comma = value.indexOf(',');
                if (comma >= 0)
                    value = value[0 .. comma];
                current.modifiedAt = value.replace(" ", "T");
                current.hasModifiedAt = current.modifiedAt.length > 0;
            }
        }
        commitCurrent();

        foreach (ref entry; entries)
        {
            if (auto meta = entry.name in metadata)
            {
                entry.isDirectory = meta.isDirectory;
                if (meta.hasSize)
                {
                    entry.size = meta.size;
                    entry.hasSize = true;
                }
                if (meta.hasModifiedAt)
                {
                    entry.modifiedAt = meta.modifiedAt;
                    entry.hasModifiedAt = true;
                }
            }
        }
        return entries;
    }

    /** List member names using `unrar lb`.
     *
     * Params:
     *     password = Archive password; empty disables password prompting.
     * Returns: Member names in archive order; empty lines are dropped.
     * Throws: `ArchivePasswordRequiredException` when a password is missing or
     *     rejected, `ArchiveToolException` when `unrar` fails without producing
     *     any name.
     */
    override string[] getEntries(string password = "")
    {
        auto passwordOption = password.length > 0 ? "-p" ~ password : "-p-";
        string[string] environment;
        environment["LC_ALL"] = "C";
        auto rc = execute(["unrar", "lb", passwordOption, absolutePath(this.fileName)],
            environment, Config.stderrPassThrough);
        if (isArchivePasswordFailure(rc.output) || rc.status == 11)
            throw new ArchivePasswordRequiredException(rc.output.length > 0
                ? rc.output : password.length > 0
                    ? "incorrect archive password"
                    : "archive password required");
        auto names = rc.output.split("\n").filter!(a => !a.empty).array;
        if (rc.status != 0 && names.length == 0)
            throw new ArchiveToolException(rc.output.length > 0
                ? rc.output : format("unrar lb failed with exit code %d",
                    rc.status));
        return names;
    }

    /** Extract one member into `destDir` using `unrar x`.
     *
     * Params:
     *     filename = Member name exactly as reported by the archive listing.
     *     destDir = Directory that receives the extracted member.
     *     password = Archive password; empty disables password prompting.
     * Returns: `true` on success.
     * Throws: `ArchivePasswordRequiredException` when a password is missing or
     *     rejected, `ArchiveToolException` for any other tool failure.
     */
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
        /** Test archive file name produced by the unittest fixture. */
        enum string fn = rarFileName;

        /** Build the RAR fixture from `expectedEntries`, replacing any old file. */
        static void createTestArchive()
        {
            deleteTestArchive;
            auto rc = execute(["rar", "a", rarFileName] ~ expectedEntries);
            assert(rc.status == 0, rc.output);
        }

        /** Remove the RAR fixture if it exists. */
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
    auto descriptors = obj.getEntryDescriptors();
    assert(descriptors.length == expectedEntries.length);
    foreach (descriptor; descriptors)
    {
        assert(descriptor.hasSize, descriptor.name);
        assert(descriptor.size > 0, descriptor.name);
        assert(descriptor.hasModifiedAt, descriptor.name);
    }
}

@("rar extraction treats option-like member names as files")
unittest
{
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : absolutePath, buildPath;
    import std.process : Config, execute, executeShell;
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

@("rar descriptors mark directory entries")
unittest
{
    import std.file : exists, mkdirRecurse, remove, rmdirRecurse, tempDir;
    import std.path : absolutePath, buildPath;
    import std.process : Config, execute, executeShell;
    import std.uuid : randomUUID;

    if (executeShell("command -v rar").status != 0)
        return;
    const root = buildPath(tempDir(), "rar-directory-entries-"
        ~ randomUUID().toString());
    const source = buildPath(root, "source", "001", "empty", "deeper");
    mkdirRecurse(source);
    const archivePath = buildPath(root, "nested.rar");
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);
    auto created = execute(["rar", "a", "-r", archivePath, "001"],
        null, Config.none, size_t.max, buildPath(root, "source"));
    assert(created.status == 0, created.output);

    auto entries = (new FileArchiveRar(archivePath)).getEntryDescriptors();
    bool foundDirectory;
    foreach (entry; entries)
        if (entry.name == "001" || entry.name == "001/empty")
        {
            assert(entry.isDirectory, entry.name);
            foundDirectory = true;
        }
    assert(foundDirectory);
}
