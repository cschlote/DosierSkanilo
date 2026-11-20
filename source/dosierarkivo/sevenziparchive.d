/** 7z archive implementation.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierarkivo.sevenziparchive;

import std.algorithm.searching : startsWith;
import std.conv : to;
import std.file : exists, remove;
import std.path : absolutePath;
import std.process : execute, executeShell;
import std.string : empty, format, replace, splitLines, strip;

import dosierarkivo.archive;
version (unittest)
{
    import dosierarkivo.factory : fileArchive;
    import dosierarkivo.testsupport;
}

/** 7z archive adapter backed by the `7z` command-line tool. */
class FileArchive7z : FileArchive
{
    /** Create a wrapper for one 7z file.
     *
     * Params:
     *     filename = Path to the 7z archive on disk; stored unchanged.
     */
    this(string filename)
    {
        super(ArchiveType._7z, filename);
    }

    /** List members with shallow size and timestamp metadata.
     *
     * Directory rows (attribute starting with `D`) are omitted. A non-password
     * failure is treated as an empty listing.
     *
     * Params:
     *     password = Archive password; empty passes a sentinel that suppresses
     *         interactive prompting.
     * Returns: Descriptors in archive order.
     * Throws: `ArchivePasswordRequiredException` when the tool reports a
     *     password or encryption problem.
     */
    private ArchiveEntryDescriptor[] listDescriptors(string password = "")
    {
        auto passwordOption = password.length > 0
            ? "-p" ~ password : "-p__dosierskanilo_no_password__";
        string[string] environment;
        environment["LC_ALL"] = "C";
        auto rc = execute(["7z", "l", passwordOption, "-slt",
            absolutePath(this.fileName)], environment);
        if (rc.status != 0 && isArchivePasswordFailure(rc.output))
            throw new ArchivePasswordRequiredException(rc.output);
        if (rc.status != 0)
            return [];

        ArchiveEntryDescriptor[] entries;
        ArchiveEntryDescriptor current;
        bool haveEntry;
        bool hasAttributes;
        bool isDirectory;
        void commit()
        {
            if (haveEntry && hasAttributes && !isDirectory)
                entries ~= current;
            current = ArchiveEntryDescriptor.init;
            haveEntry = false;
            hasAttributes = false;
            isDirectory = false;
        }
        foreach (line; rc.output.splitLines)
        {
            const text = line.strip;
            if (text.length == 0)
            {
                commit();
                continue;
            }
            if (text.startsWith("Path = "))
            {
                commit();
                current.name = text[7 .. $];
                haveEntry = true;
            }
            else if (haveEntry && text.startsWith("Size = "))
            {
                try
                {
                    current.size = text[7 .. $].to!ulong;
                    current.hasSize = true;
                }
                catch (Exception)
                {
                }
            }
            else if (haveEntry && text.startsWith("Modified = "))
            {
                auto value = text[11 .. $];
                if (value.length > 19)
                    value = value[0 .. 19];
                current.modifiedAt = value.replace(" ", "T");
                current.hasModifiedAt = current.modifiedAt.length > 0;
            }
            else if (haveEntry && text.startsWith("Attributes = "))
            {
                hasAttributes = true;
                const attrs = text[13 .. $];
                isDirectory = attrs.length > 0 && attrs[0] == 'D';
            }
        }
        commit();
        return entries;
    }

    /** List file member names using `7z l -slt`.
     *
     * Params:
     *     password = Archive password; empty passes a sentinel that suppresses
     *         interactive prompting.
     * Returns: Member names in archive order.
     * Throws: `ArchivePasswordRequiredException` when the tool reports a
     *     password or encryption problem.
     */
    override string[] getEntries(string password = "")
    {
        string[] names;
        foreach (descriptor; listDescriptors(password))
            names ~= descriptor.name;
        return names;
    }

    /** Return descriptors enriched with shallow size/timestamp metadata.
     *
     * Params:
     *     password = Archive password; empty passes a sentinel that suppresses
     *         interactive prompting.
     * Returns: Descriptors in archive order.
     * Throws: `ArchivePasswordRequiredException` when the tool reports a
     *     password or encryption problem.
     */
    override ArchiveEntryDescriptor[] getEntryDescriptors(string password = "")
    {
        return finalizeDescriptors(listDescriptors(password));
    }

    /** Extract one member into `destDir` using `7z x`.
     *
     * Params:
     *     filename = Member name exactly as reported by the archive listing.
     *     destDir = Directory that receives the extracted member.
     *     password = Archive password; empty passes a sentinel that suppresses
     *         interactive prompting.
     *     cancellation = Optional cooperative cancellation flag.
     * Returns: `true` on success.
     * Throws: `ArchivePasswordRequiredException` when a password is missing or
     *     rejected, `ArchiveToolException` for any other tool failure.
     */
    override bool extractEntry(string filename, string destDir, string password = "",
        shared(bool)* cancellation = null)
    {
        auto passwordOption = password.length > 0
            ? "-p" ~ password : "-p__dosierskanilo_no_password__";
        enforceArchiveToolResult(runArchiveTool(["7z", "x", passwordOption,
            "-o" ~ destDir, absolutePath(this.fileName), "--", filename],
            cancellation));
        return true;
    }

    /** Extract a named subset of members with one `7z` invocation.
     *
     * Params:
     *     members = Member names without wildcard metacharacters.
     *     destDir = Directory that receives the extracted files.
     *     password = Archive password; empty suppresses interactive prompting.
     *     cancellation = Optional cooperative cancellation flag.
     * Returns: `true` on success.
     * Throws: `ArchivePasswordRequiredException` when a password is missing or
     *     rejected, `ArchiveToolException` for any other tool failure.
     */
    override bool extractEntriesTo(string[] members, string destDir,
        string password = "", shared(bool)* cancellation = null)
    {
        auto passwordOption = password.length > 0
            ? "-p" ~ password : "-p__dosierskanilo_no_password__";
        auto command = ["7z", "x", passwordOption, "-y", "-bd",
            "-o" ~ destDir, absolutePath(this.fileName), "--"];
        command ~= members;
        enforceArchiveToolResult(runArchiveTool(command, cancellation));
        return true;
    }

    /** Extract the complete archive into one staging directory with `7z`.
     *
     * Params:
     *     destDir = directory that receives the complete archive tree
     *     password = archive password; empty suppresses interactive prompting
     *     cancellation = optional cooperative cancellation flag
     * Returns: `true` on success.
     * Throws: `ArchivePasswordRequiredException` when a password is missing or
     *     rejected, `ArchiveToolException` for any other tool failure.
     */
    override bool extractAllTo(string destDir, string password = "",
        shared(bool)* cancellation = null)
    {
        auto passwordOption = password.length > 0
            ? "-p" ~ password : "-p__dosierskanilo_no_password__";
        enforceArchiveToolResult(runArchiveTool(["7z", "x", passwordOption,
            "-y", "-bd", "-o" ~ destDir, absolutePath(this.fileName)],
            cancellation));
        return true;
    }

    version (unittest)
    {
        /** Test archive file name produced by the unittest fixture. */
        enum string fn = _7zFileName;

        /** Build the 7z fixture from `expectedEntries`, replacing any old file. */
        static void createTestArchive()
        {
            deleteTestArchive;
            auto rc = execute(["7z", "a", _7zFileName] ~ expectedEntries);
            assert(rc.status == 0, rc.output);
        }

        /** Remove the 7z fixture if it exists. */
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
    import std.path : absolutePath, buildPath;
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

@("7z descriptors expose shallow member metadata")
unittest
{
    import std.file : exists, getSize, mkdirRecurse, rmdirRecurse, tempDir,
        write;
    import std.path : buildPath;
    import std.process : Config, execute, executeShell;
    import std.uuid : randomUUID;

    if (executeShell("command -v 7z").status != 0)
        return;
    const root = buildPath(tempDir(), "7z-shallow-metadata-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);
    const payload = buildPath(root, "member with space.txt");
    write(payload, "payload-content");
    const archivePath = buildPath(root, "sample.7z");
    auto created = execute(["7z", "a", archivePath, "member with space.txt"],
        null, Config.none, size_t.max, root);
    assert(created.status == 0, created.output);

    auto archive = new FileArchive7z(archivePath);
    auto descriptors = archive.getEntryDescriptors();
    assert(descriptors.length == 1);
    assert(descriptors[0].name == "member with space.txt",
        descriptors[0].name);
    assert(descriptors[0].hasSize);
    assert(descriptors[0].size == getSize(payload));
    assert(descriptors[0].hasModifiedAt);
    assert(descriptors[0].modifiedAt.length >= 19,
        descriptors[0].modifiedAt);
}

@("7z solid listing keeps member names that start with a digit")
unittest
{
    import std.algorithm.searching : endsWith, startsWith;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.process : Config, execute, executeShell;
    import std.uuid : randomUUID;

    if (executeShell("command -v 7z").status != 0)
        return;
    const root = buildPath(tempDir(), "7z-solid-digit-name-"
        ~ randomUUID().toString());
    const source = buildPath(root, "source", "2 german dogs");
    const output = buildPath(root, "output");
    mkdirRecurse(source);
    mkdirRecurse(output);
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);
    write(buildPath(source, "saliva-1.jpg"), "first");
    write(buildPath(source, "saliva-2.jpg"), "second payload");
    const archivePath = buildPath(root, "solid.7z");
    auto created = execute(["7z", "a", "-bd", "-bso0", "-ms=on", archivePath,
        "2 german dogs"], null, Config.none, size_t.max,
        buildPath(root, "source"));
    assert(created.status == 0, created.output);

    auto archive = new FileArchive7z(archivePath);
    auto descriptors = archive.getEntryDescriptors();
    assert(descriptors.length == 2);
    foreach (descriptor; descriptors)
    {
        assert(descriptor.name.startsWith("2 german dogs/"), descriptor.name);
        assert(descriptor.relativePath.startsWith("2 german dogs/"),
            descriptor.relativePath);
        assert(descriptor.hasSize, descriptor.name);
        assert(descriptor.hasModifiedAt, descriptor.name);
        const expectedSize = descriptor.name.endsWith("saliva-1.jpg")
            ? "first".length : "second payload".length;
        assert(descriptor.size == expectedSize, descriptor.name);
    }
    assert(archive.extractEntry("2 german dogs/saliva-1.jpg", output));
    assert(exists(buildPath(output, "2 german dogs", "saliva-1.jpg")));
}

@("7z bulk extraction writes all members")
unittest
{
    import std.file : exists, mkdirRecurse, readText, rmdirRecurse, tempDir,
        write;
    import std.path : buildPath;
    import std.process : Config, execute, executeShell;
    import std.uuid : randomUUID;

    if (executeShell("command -v 7z").status != 0)
        return;
    const root = buildPath(tempDir(), "7z-bulk-extract-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);
    write(buildPath(root, "first.txt"), "first");
    write(buildPath(root, "second.txt"), "second");
    const archivePath = buildPath(root, "bulk.7z");
    auto created = execute(["7z", "a", "-bd", "-y", archivePath,
        "first.txt", "second.txt"], null, Config.none, size_t.max, root);
    assert(created.status == 0, created.output);

    const output = buildPath(root, "output");
    mkdirRecurse(output);
    auto archive = new FileArchive7z(archivePath);
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
