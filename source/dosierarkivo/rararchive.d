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
import std.path : absolutePath, buildPath, dirSeparator;
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
        /* `unrar` encodes member names for the console locale; a plain C
         * locale would replace every non-ASCII byte with `?`. The numeric and
         * date fields stay stable under a UTF-8-capable C locale. */
        const auto consoleLocale = archiveConsoleLocale();
        if (consoleLocale.length > 0)
            environment["LC_ALL"] = consoleLocale;
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
        /* `unrar` encodes member names for the console locale; a plain C
         * locale would replace every non-ASCII byte with `?`. */
        const auto consoleLocale = archiveConsoleLocale();
        if (consoleLocale.length > 0)
            environment["LC_ALL"] = consoleLocale;
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
     *     cancellation = Optional cooperative cancellation flag.
     * Returns: `true` on success.
     * Throws: `ArchivePasswordRequiredException` when a password is missing or
     *     rejected, `ArchiveToolException` for any other tool failure.
     */
    override bool extractEntry(string filename, string destDir, string password = "",
        shared(bool)* cancellation = null)
    {
        auto tarPath = buildPath(getcwd(), this.fileName);
        auto passwordOption = password.length > 0 ? "-p" ~ password : "-p-";
        auto result = runArchiveTool(["unrar", "x", passwordOption, tarPath,
            "--", filename, destDir], cancellation);
        if (result.status != 0 && isArchivePasswordFailure(result.output))
            throw new ArchivePasswordRequiredException(result.output);
        if (result.status != 0)
            throw new ArchiveToolException(result.output);
        return true;
    }

    /** Extract a named subset of members with one `unrar` invocation.
     *
     * Params:
     *     members = Member names without wildcard metacharacters.
     *     destDir = Directory that receives the extracted files.
     *     password = Archive password; empty disables password prompting.
     *     cancellation = Optional cooperative cancellation flag.
     * Returns: `true` on success.
     * Throws: `ArchivePasswordRequiredException` when a password is missing or
     *     rejected, `ArchiveToolException` for any other tool failure.
     */
    override bool extractEntriesTo(string[] members, string destDir,
        string password = "", shared(bool)* cancellation = null)
    {
        auto archivePath = buildPath(getcwd(), this.fileName);
        auto passwordOption = password.length > 0 ? "-p" ~ password : "-p-";
        auto command = ["unrar", "x", "-o+", "-idq", passwordOption,
            archivePath, "--"];
        command ~= members;
        command ~= destDir ~ dirSeparator;
        auto result = runArchiveTool(command, cancellation);
        if (result.status != 0 && isArchivePasswordFailure(result.output))
            throw new ArchivePasswordRequiredException(result.output);
        if (result.status != 0)
            throw new ArchiveToolException(result.output);
        return true;
    }

    /** Extract the complete archive into one staging directory with `unrar`.
     *
     * Params:
     *     destDir = directory that receives the complete archive tree
     *     password = archive password; empty disables password prompting
     *     cancellation = optional cooperative cancellation flag
     * Returns: `true` on success.
     * Throws: `ArchivePasswordRequiredException` when a password is missing or
     *     rejected, `ArchiveToolException` for any other tool failure.
     */
    override bool extractAllTo(string destDir, string password = "",
        shared(bool)* cancellation = null)
    {
        auto archivePath = buildPath(getcwd(), this.fileName);
        auto passwordOption = password.length > 0 ? "-p" ~ password : "-p-";
        auto result = runArchiveTool(["unrar", "x", "-o+", "-idq",
            passwordOption, archivePath, "--", ".", destDir ~ dirSeparator],
            cancellation);
        if (result.status != 0 && isArchivePasswordFailure(result.output))
            throw new ArchivePasswordRequiredException(result.output);
        if (result.status != 0)
            throw new ArchiveToolException(result.output);
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
    import std.path : absolutePath, buildPath, dirSeparator;
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
    import std.path : absolutePath, buildPath, dirSeparator;
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

@("rar listings and extraction keep heavy UTF-8 member names")
unittest
{
    import std.file : exists, mkdirRecurse, readText, rmdirRecurse, tempDir,
        write;
    import std.path : buildPath, dirSeparator;
    import std.process : Config, execute, executeShell;
    import std.uuid : randomUUID;

    if (executeShell("command -v rar").status != 0
        || executeShell("command -v unrar").status != 0)
        return;
    import std.algorithm.searching : canFind;
    const root = buildPath(tempDir(), "rar-utf8-members-"
        ~ randomUUID().toString());
    const source = buildPath(root, "source");
    const output = buildPath(root, "output");
    mkdirRecurse(source);
    mkdirRecurse(output);
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);

    enum firstName = "Müller-Émile_日本語_🎉.txt";
    enum secondName = "ملف_عربي.txt";
    write(buildPath(source, firstName), "first payload");
    write(buildPath(source, secondName), "second payload");
    const archivePath = buildPath(root, "utf8.rar");
    auto created = execute(["rar", "a", "-idq", "-ep1", archivePath,
        firstName, secondName], null, Config.none, size_t.max, source);
    assert(created.status == 0, created.output);

    auto archive = new FileArchiveRar(archivePath);
    auto entries = archive.getEntries();
    assert(entries.length == 2, entries.to!string);
    assert(entries.canFind(firstName), entries.to!string);
    assert(entries.canFind(secondName), entries.to!string);

    auto descriptors = archive.getEntryDescriptors();
    assert(descriptors.length == 2, descriptors.to!string);
    foreach (descriptor; descriptors)
    {
        assert(descriptor.hasSafePath, descriptor.name);
        assert(descriptor.hasSize, descriptor.name);
        assert(descriptor.size == (descriptor.name == firstName
            ? "first payload".length : "second payload".length),
            descriptor.name);
    }

    assert(archive.extractEntry(firstName, output));
    assert(readText(buildPath(output, firstName)) == "first payload");
    assert(archive.extractEntriesTo([secondName], output));
    assert(readText(buildPath(output, secondName)) == "second payload");
}

@("rar bulk extraction writes all members")
unittest
{
    import std.file : exists, mkdirRecurse, readText, rmdirRecurse, tempDir,
        write;
    import std.path : buildPath;
    import std.process : Config, execute, executeShell;
    import std.uuid : randomUUID;

    if (executeShell("command -v rar").status != 0
        || executeShell("command -v unrar").status != 0)
        return;
    const root = buildPath(tempDir(), "rar-bulk-extract-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);
    write(buildPath(root, "first.txt"), "first");
    write(buildPath(root, "second.txt"), "second");
    const archivePath = buildPath(root, "bulk.rar");
    auto created = execute(["rar", "a", "-idq", "-ep1", archivePath,
        "first.txt", "second.txt"], null, Config.none, size_t.max, root);
    assert(created.status == 0, created.output);

    const output = buildPath(root, "output");
    mkdirRecurse(output);
    auto archive = new FileArchiveRar(archivePath);
    assert(archive.extractAllTo(output));
    assert(readText(buildPath(output, "first.txt")) == "first");
    assert(readText(buildPath(output, "second.txt")) == "second");

    const subset = buildPath(root, "subset");
    mkdirRecurse(subset);
    assert(archive.extractEntriesTo(["first.txt"], subset));
    assert(readText(buildPath(subset, "first.txt")) == "first");
    assert(!exists(buildPath(subset, "second.txt")),
        "named-subset extraction must not extract unlisted members");
}
