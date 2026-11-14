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
import std.path : absolutePath, buildPath;
import std.process : execute, executeShell;
import std.regex : matchFirst;
import std.stdio : write;
import std.string : empty, format, split, splitLines, strip;

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
        auto rc = execute(["tar", "-tf", absolutePath(this.fileName)]);
        if (rc.status != 0)
            throw new ArchiveToolException(rc.output);
        return rc.output.split("\n").filter!(a => !a.empty).array;
    }

    /** Metadata parsed from one `tar -tvf` row. */
    private struct TarMetadata
    {
        ulong size; /// Uncompressed member size.
        string modifiedAt; /// ISO-like timestamp.
        bool hasSize; /// Whether `size` is meaningful.
        bool hasModifiedAt; /// Whether `modifiedAt` is meaningful.
    }

    /** Parse size and timestamp columns from `tar -tvf` output.
     *
     * Names are ignored; the descriptor names come from `tar -tf` so symlink
     * decorations such as ` -> target` cannot corrupt the stored member name.
     *
     * Params:
     *     output = Complete standard output of `tar -tvf`.
     *     fullTime = Whether the listing used `--full-time`.
     * Returns: Metadata rows in listing order.
     */
    private TarMetadata[] parseTarLongListMetadata(string output,
        bool fullTime) const
    {
        TarMetadata[] entries;
        foreach (line; output.splitLines)
        {
            if (line.strip.empty)
                continue;
            auto match = matchFirst(line, fullTime
                ? `^\S+\s+\S+\s+(\d+)\s+(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2}:\d{2})(?:\.[0-9]+)?(?:\s+[+-]\d{4})?\s+`
                : `^\S+\s+\S+\s+(\d+)\s+(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2})\s+`);
            if (match.empty)
                continue;
            TarMetadata metadata;
            try
                metadata.size = match.captures[1].to!ulong;
            catch (Exception)
                continue;
            metadata.hasSize = true;
            metadata.modifiedAt = match.captures[2] ~ "T"
                ~ match.captures[3];
            if (match.captures[3].length == 5)
                metadata.modifiedAt ~= ":00";
            metadata.hasModifiedAt = true;
            entries ~= metadata;
        }
        return entries;
    }

    /** Return descriptors enriched with shallow size/timestamp metadata.
     *
     * GNU tar's `--full-time` supplies second precision. Other tar
     * implementations fall back to the regular verbose listing. If row counts
     * differ from `tar -tf`, names-only descriptors are returned.
     *
     * Params:
     *     password = Accepted for interface compatibility.
     * Returns: Descriptors in listing order, or `null` when the base listing
     *     returns `null`.
     */
    override ArchiveEntryDescriptor[] getEntryDescriptors(string password = "")
    {
        auto names = getEntries(password);
        if (names is null)
            return null;
        string[string] environment;
        environment["LC_ALL"] = "C";
        const archivePath = absolutePath(this.fileName);
        auto listing = execute(["tar", "--full-time", "--numeric-owner",
            "-tvf", archivePath], environment);
        bool fullTime = listing.status == 0;
        if (!fullTime)
            listing = execute(["tar", "--numeric-owner", "-tvf", archivePath],
                environment);
        if (listing.status == 0)
        {
            auto metadata = parseTarLongListMetadata(listing.output, fullTime);
            if (metadata.length == names.length)
            {
                ArchiveEntryDescriptor[] result;
                foreach (index, name; names)
                {
                    ArchiveEntryDescriptor descriptor;
                    descriptor.name = name;
                    if (metadata[index].hasSize)
                    {
                        descriptor.size = metadata[index].size;
                        descriptor.hasSize = true;
                    }
                    if (metadata[index].hasModifiedAt)
                    {
                        descriptor.modifiedAt = metadata[index].modifiedAt;
                        descriptor.hasModifiedAt = true;
                    }
                    result ~= descriptor;
                }
                return finalizeDescriptors(result);
            }
        }
        return super.getEntryDescriptors(password);
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

    /** Extract the complete archive into one staging directory with `tar`.
     *
     * Params:
     *     destDir = directory that receives the complete archive tree
     *     password = accepted for interface compatibility; TAR extraction does
     *         not use it
     *     cancellation = optional cooperative cancellation flag
     * Returns: `true` on success.
     * Throws: `ArchiveToolException` when `tar` fails.
     */
    override bool extractAllTo(string destDir, string password = "",
        shared(bool)* cancellation = null)
    {
        auto result = runArchiveTool(["tar", "-xf",
            absolutePath(this.fileName), "-C", destDir], cancellation);
        if (result.status != 0)
            throw new ArchiveToolException(result.output);
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
    import std.path : absolutePath, buildPath;
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

@("tar descriptors expose shallow member metadata")
unittest
{
    import std.file : exists, getSize, mkdirRecurse, rmdirRecurse, tempDir,
        write;
    import std.path : buildPath;
    import std.process : execute;
    import std.uuid : randomUUID;

    const root = buildPath(tempDir(), "tar-shallow-metadata-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);
    const payload = buildPath(root, "member with space.txt");
    write(payload, "payload-content");
    const archivePath = buildPath(root, "sample.tar");
    auto created = execute(["tar", "-cf", archivePath, "-C", root,
        "member with space.txt"]);
    assert(created.status == 0, created.output);

    auto archive = new FileArchiveTar(archivePath);
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

@("compressed tar variants use the tar adapter")
unittest
{
    import std.file : exists, getSize, mkdirRecurse, rmdirRecurse, tempDir,
        write;
    import std.path : buildPath;
    import std.process : execute, executeShell;
    import std.uuid : randomUUID;

    struct Variant
    {
        string suffix;
        string[] tarOptions;
        string tool;
    }
    const variants = [
        Variant(".tar.gz", ["-czf"], "gzip"),
        Variant(".tar.xz", ["-cJf"], "xz"),
        Variant(".tar.zst", ["--zstd", "-cf"], "zstd"),
    ];
    foreach (variant; variants)
    {
        if (executeShell("command -v " ~ variant.tool).status != 0)
            continue;
        const root = buildPath(tempDir(), "tar-compressed-"
            ~ randomUUID().toString());
        mkdirRecurse(root);
        scope (exit)
            if (exists(root))
                rmdirRecurse(root);
        const payload = buildPath(root, "payload.txt");
        write(payload, "compressed-payload");
        const archivePath = root ~ variant.suffix;
        auto created = execute(["tar"] ~ variant.tarOptions
            ~ [archivePath, "-C", root, "payload.txt"]);
        if (created.status != 0)
            continue; // this tar build lacks the requested compressor

        auto archive = fileArchive(archivePath);
        assert(archive !is null, variant.suffix);
        assert(archive.fileType == ArchiveType.tar, variant.suffix);
        auto descriptors = archive.getEntryDescriptors();
        assert(descriptors.length == 1, variant.suffix);
        assert(descriptors[0].hasSize);
        assert(descriptors[0].size == getSize(payload));
        assert(descriptors[0].hasModifiedAt);

        const output = buildPath(root, "output");
        mkdirRecurse(output);
        assert(archive.extractEntry(descriptors[0], output),
            variant.suffix);
        assert(exists(buildPath(output, "payload.txt")), variant.suffix);
    }
}

@("tar bulk extraction writes all members")
unittest
{
    import std.file : exists, mkdirRecurse, readText, rmdirRecurse, tempDir,
        write;
    import std.path : buildPath;
    import std.process : execute;
    import std.uuid : randomUUID;

    const root = buildPath(tempDir(), "tar-bulk-extract-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);
    write(buildPath(root, "first.txt"), "first");
    write(buildPath(root, "second.txt"), "second");
    const archivePath = buildPath(root, "bulk.tar");
    auto created = execute(["tar", "-cf", archivePath, "-C", root,
        "first.txt", "second.txt"]);
    assert(created.status == 0, created.output);

    const output = buildPath(root, "output");
    mkdirRecurse(output);
    auto archive = new FileArchiveTar(archivePath);
    assert(archive.extractAllTo(output));
    assert(readText(buildPath(output, "first.txt")) == "first");
    assert(readText(buildPath(output, "second.txt")) == "second");
}
