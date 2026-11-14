/** ZIP archive implementation.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierarkivo.ziparchive;

import std.algorithm : filter, map;
import std.algorithm.searching : canFind;
import std.array : array;
import std.conv : to;
import std.file : exists, getcwd, remove;
import std.path : absolutePath, buildPath, isAbsolute;
import std.process : execute, executeShell;
import std.regex : matchFirst;
import std.stdio : stderr, write;
import std.string : empty, format, splitLines, startsWith, strip;

import dosierarkivo.archive;
version (unittest)
{
    import dosierarkivo.factory : fileArchive;
    import dosierarkivo.testsupport;
}

/** Implementation for zip files.
 *
 * We use the unzip utility to get the list of entries and to extract files. The unzip utility is available
 * on most systems and supports a wide range of zip formats. The output of the unzip utility is parsed to
 * get the list of entries and to extract files.
 */
class FileArchiveZip : FileArchive
{
    /** Parse the human-readable `unzip -l` listing into member names.
     *
     * Only rows between the dashed header and the dashed trailer are considered,
     * and rows that do not match the size/date/time columns are skipped.
     *
     * Params:
     *     output = Complete standard output of `unzip -l`.
     * Returns: Member names in listing order, or an empty array when no row
     *     could be parsed.
     */
    private string[] parseUnzipLongListOutput(string output) const
    {
        string[] entries;
        bool inEntrySection = false;

        foreach (line; output.splitLines)
        {
            auto trimmed = line.strip;
            if (trimmed.empty)
                continue;

            if (!inEntrySection)
            {
                if (trimmed.startsWith("---------"))
                    inEntrySection = true;
                continue;
            }

            if (trimmed.startsWith("---------"))
                break;

            auto m = matchFirst(line, `^\s*\d+\s+\S+\s+\S+\s+(.+?)\s*$`);
            if (m.empty)
                continue;

            auto entryName = m.captures[1];
            if (!entryName.empty)
                entries ~= entryName;
        }

        return entries;
    }

    /** Metadata parsed from one `unzip -l` row. */
    private struct ZipMetadata
    {
        ulong size; /// Uncompressed member size.
        string modifiedAt; /// ISO-like timestamp when the listing supplied one.
        bool hasSize; /// Whether `size` is meaningful.
        bool hasModifiedAt; /// Whether `modifiedAt` is meaningful.
    }

    /** Parse size and timestamp columns from `unzip -l` output.
     *
     * Names are deliberately ignored; callers pair these rows with the exact
     * names returned by `getEntries()` so spaces and duplicate names cannot
     * shift the descriptor identity.
     *
     * Params:
     *     output = Complete standard output of `unzip -l`.
     * Returns: Metadata rows in listing order.
     */
    private ZipMetadata[] parseUnzipLongListMetadata(string output) const
    {
        ZipMetadata[] entries;
        bool inEntrySection;
        foreach (line; output.splitLines)
        {
            const trimmed = line.strip;
            if (trimmed.empty)
                continue;
            if (!inEntrySection)
            {
                if (trimmed.startsWith("---------"))
                    inEntrySection = true;
                continue;
            }
            if (trimmed.startsWith("---------"))
                break;
            auto match = matchFirst(line,
                `^\s*(\d+)\s+(\S+)\s+(\S+)\s{2,}`);
            if (match.empty)
                continue;
            ZipMetadata metadata;
            try
                metadata.size = match.captures[1].to!ulong;
            catch (Exception)
                continue;
            metadata.hasSize = true;
            const date = match.captures[2];
            const time = match.captures[3];
            if (date.length == 10 && date[4] == '-' && date[7] == '-')
            {
                metadata.modifiedAt = date ~ "T" ~ time;
                if (metadata.modifiedAt.length == 16)
                    metadata.modifiedAt ~= ":00";
                metadata.hasModifiedAt = true;
            }
            entries ~= metadata;
        }
        return entries;
    }

    /** Return descriptors enriched with shallow size/timestamp metadata.
     *
     * Names come from `getEntries()` so whitespace and duplicate names retain
     * their exact spelling. If the long listing cannot be parsed or has a
     * different row count, the adapter falls back to names-only descriptors.
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
        auto listing = execute(["unzip", "-l", absolutePath(this.fileName)],
            environment);
        if (listing.status == 0)
        {
            auto metadata = parseUnzipLongListMetadata(listing.output);
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

    /** Create a wrapper for one ZIP file.
     *
     * Params:
     *     filename = Path to the ZIP archive on disk; stored unchanged.
     */
    this(string filename)
    {
        super(ArchiveType.zip, filename);
    }

    /** List member names using `unzip -Z1`, falling back to `unzip -l`.
     *
     * Params:
     *     password = Accepted for interface compatibility; ZIP listing does not
     *         use it.
     * Returns: Member names in archive order, or an empty array when the
     *     listing tool fails or its output cannot be parsed.
     * Throws: `ArchivePasswordRequiredException` when the tool reports a
     *     password or encryption problem.
     */
    override string[] getEntries(string password = "")
    {
        auto rcMachineReadable = execute(["unzip", "-Z1",
            absolutePath(this.fileName)]);
        if (rcMachineReadable.status == 0)
        {
            return rcMachineReadable.output
                .splitLines
                .filter!(line => line.length > 0)
                .array;
        }
        if (isArchivePasswordFailure(rcMachineReadable.output))
            throw new ArchivePasswordRequiredException(rcMachineReadable.output);

        stderr.writeln("WARNING: unzip -Z1 failed for '", this.fileName,
            "'. Falling back to parsing unzip -l output.");

        auto rcLongList = execute(["unzip", "-l",
            absolutePath(this.fileName)]);
        if (rcLongList.status != 0)
        {
            if (isArchivePasswordFailure(rcLongList.output))
                throw new ArchivePasswordRequiredException(rcLongList.output);
            stderr.writeln("WARNING: unzip -l failed for '", this.fileName,
                "'. Skipping archive entry scan.");
            return [];
        }

        auto entries = parseUnzipLongListOutput(rcLongList.output);
        if (entries.empty)
        {
            stderr.writeln("WARNING: Could not parse unzip -l output for '", this.fileName,
                "'. Skipping archive entry scan.");
        }
        return entries;
    }

    /** Extract one member into `destDir` using `unzip`.
     *
     * Params:
     *     filename = Member name exactly as reported by the archive listing.
     *     destDir = Directory that receives the extracted file.
     *     password = Archive password; empty selects the tool's default.
     * Returns: `true` on success.
     * Throws: `ArchivePasswordRequiredException` when a password is missing or
     *     rejected, `ArchiveToolException` for any other tool failure.
     */
    override bool extractEntry(string filename, string destDir, string password = "")
    {
        /* Info-ZIP expands filename operands as glob patterns. The descriptor
         * overload uses index-based extraction; reject ambiguous names here. */
        if (filename.canFind("*") || filename.canFind("?")
            || filename.canFind("["))
            throw new ArchiveToolException(
                "ZIP member names with glob metacharacters require index-based "
                ~ "extraction: " ~ filename);
        auto zipPath = buildPath(getcwd(), this.fileName);
        auto rc = execute(["unzip", "-P", password, "-d", destDir, "--", zipPath, filename]);
        if (rc.status != 0 && isArchivePasswordFailure(rc.output))
            throw new ArchivePasswordRequiredException(rc.output);
        if (rc.status != 0)
            throw new ArchiveToolException(rc.output);
        return true;
    }

    /** Report whether a specific duplicate occurrence can be extracted.
     *
     * The implementation delegates duplicate selection to Python's `zipfile`
     * module, so this is `true` only when `python3` is runnable.
     *
     * Returns: `true` when index-based extraction is available.
     */
    override @property bool supportsEntryOccurrence() const
    {
        return executeShell("python3 --version").status == 0;
    }

    /** Extract the exact occurrence identified by a descriptor.
     *
     * Unique names are delegated to the name-based overload. Duplicate names
     * are extracted by their archive index through Python's `zipfile` module,
     * which also verifies that the index still names the expected member.
     *
     * Params:
     *     descriptor = Entry identity returned by `getEntryDescriptors`.
     *     destDir = Directory that receives the extracted member.
     *     password = Archive password; empty means no password.
     * Returns: `true` on success, `false` when duplicate selection is needed
     *     but `python3` is unavailable or the extraction script fails.
     * Throws: `ArchivePasswordRequiredException` when a password is missing or
     *     rejected.
     */
    override bool extractEntry(ArchiveEntryDescriptor descriptor, string destDir,
        string password = "")
    {
        if (!descriptor.hasSafePath)
            return false;
        const bool needsIndexSelection = descriptor.hasDuplicateName
            || descriptor.name.canFind("*") || descriptor.name.canFind("?")
            || descriptor.name.canFind("[");
        if (!needsIndexSelection)
            return extractEntry(descriptor.name, destDir, password);
        if (!supportsEntryOccurrence)
            return false;

        enum extractionScript = "import os, shutil, sys, zipfile\n"
            ~ "archive, index, dest, member, expected, password = sys.argv[1:]\n"
            ~ "with zipfile.ZipFile(archive) as z:\n"
            ~ "    info = z.infolist()[int(index)]\n"
            ~ "    if info.filename != expected:\n"
            ~ "        raise RuntimeError('archive entry index/name mismatch')\n"
            ~ "    os.makedirs(os.path.dirname(os.path.join(dest, member)), exist_ok=True)\n"
            ~ "    with z.open(info, 'r', pwd=password.encode() if password else None) as src:\n"
            ~ "        with open(os.path.join(dest, member), 'wb') as out:\n"
            ~ "            shutil.copyfileobj(src, out)\n";
        auto zipPath = isAbsolute(this.fileName) ? this.fileName
            : buildPath(getcwd(), this.fileName);
        auto rc = execute(["python3", "-c", extractionScript, zipPath,
            descriptor.index.to!string, destDir, descriptor.relativePath,
            descriptor.name, password]);
        if (rc.status != 0 && isArchivePasswordFailure(rc.output))
            throw new ArchivePasswordRequiredException(rc.output);
        return rc.status == 0;
    }

    /** Extract the complete archive into one staging directory with `unzip`.
     *
     * Params:
     *     destDir = directory that receives the complete archive tree
     *     password = archive password; empty selects the tool's default
     * Returns: `true` on success.
     * Throws: `ArchivePasswordRequiredException` when a password is missing or
     *     rejected, `ArchiveToolException` for any other tool failure.
     */
    override bool extractAllTo(string destDir, string password = "")
    {
        auto zipPath = isAbsolute(this.fileName) ? this.fileName
            : buildPath(getcwd(), this.fileName);
        auto rc = execute(["unzip", "-P", password, "-o", "-q", "-d", destDir,
            "--", zipPath]);
        if (rc.status != 0 && isArchivePasswordFailure(rc.output))
            throw new ArchivePasswordRequiredException(rc.output);
        if (rc.status != 0)
            throw new ArchiveToolException(rc.output);
        return true;
    }

    version (unittest)
    {
        /** Test archive file name produced by the unittest fixture. */
        enum string fn = zipFileName;

        /** Build the ZIP fixture from `expectedEntries`, replacing any old file. */
        static void createTestArchive()
        {
            if (fn.exists)
                remove(fn);
            auto rc = execute(["zip", "-q", zipFileName] ~ expectedEntries);
            write(rc.output);
            assert(rc.status == 0, rc.output);
        }

        /** Remove the ZIP fixture if it exists. */
        static void deleteTestArchive()
        {
            if (fn.exists)
                remove(fn);
        }
    }
}

@("class FileArchiveZip")
unittest
{
    FileArchiveZip.createTestArchive;
    scope (exit)
        FileArchiveZip.deleteTestArchive;

    auto obj = fileArchive(zipFileName);
    testAbstractImpl(obj);
}

@("zip list parser tolerates output drift")
unittest
{
    auto obj = new FileArchiveZip("dummy.zip");
    auto parsed = obj.parseUnzipLongListOutput("unexpected output\nwithout expected columns\n");
    assert(parsed.length == 0);
}

@("zip archive missing file fallback")
unittest
{
    auto obj = new FileArchiveZip("definitely-missing-archive.zip");
    auto entries = obj.getEntries();
    assert(entries.length == 0);
}

@("archive extraction with special filenames")
unittest
{
    import std.algorithm.searching : countUntil;
    import std.conv : to;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.process : execute, thisProcessID;

    auto tmpRoot = buildPath(tempDir, "dosierskanilo-archive-safe-" ~ thisProcessID.to!string);
    if (tmpRoot.exists)
        rmdirRecurse(tmpRoot);
    mkdirRecurse(tmpRoot);
    scope (exit)
        if (tmpRoot.exists)
            rmdirRecurse(tmpRoot);

    auto specialEntryName = "special 'quoted' ;$ file.txt";
    auto specialSourceFile = buildPath(tmpRoot, specialEntryName);
    write(specialSourceFile, "archive safety regression test\n");

    auto zipArchiveName = "special ;$ 'archive'.zip";
    auto zipArchivePath = buildPath(tmpRoot, zipArchiveName);
    auto zipCreate = execute(["zip", "-q", "-j", zipArchivePath, specialSourceFile]);
    assert(zipCreate.status == 0, zipCreate.output);

    auto zipObj = fileArchive(zipArchivePath);
    assert(zipObj !is null);
    auto zipEntries = zipObj.getEntries();
    assert(zipEntries.countUntil(specialEntryName) >= 0, zipEntries.to!string);

    auto zipExtractDir = buildPath(tmpRoot, "extract zip ;$ dir");
    mkdirRecurse(zipExtractDir);
    assert(zipObj.extractEntry(specialEntryName, zipExtractDir));
    assert(buildPath(zipExtractDir, specialEntryName).exists);
}

@("zip duplicate occurrence extraction selects exact content")
unittest
{
    import std.file : exists, mkdirRecurse, readText, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.process : execute, executeShell;
    import std.uuid : randomUUID;

    if (executeShell("command -v python3").status != 0)
        return;
    const auto root = buildPath(tempDir(), "zip-duplicate-occurrence-"
        ~ randomUUID().toString());
    const auto archivePath = buildPath(root, "duplicate.zip");
    const auto firstDirectory = buildPath(root, "first");
    const auto secondDirectory = buildPath(root, "second");
    mkdirRecurse(root);
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);

    const auto createScript = "import sys, zipfile; z=zipfile.ZipFile(sys.argv[1], 'w'); "
        ~ "z.writestr('same.txt', 'first occurrence'); "
        ~ "z.writestr('same.txt', 'second occurrence'); z.close()";
    const auto created = execute(["python3", "-c", createScript, archivePath]);
    assert(created.status == 0, created.output);
    auto archive = new FileArchiveZip(archivePath);
    assert(archive.supportsEntryOccurrence);
    auto entries = archive.getEntryDescriptors();
    assert(entries.length == 2);
    assert(entries[0].hasDuplicateName && entries[1].hasDuplicateName);
    assert(entries[0].occurrence == 0 && entries[1].occurrence == 1);
    assert(archive.extractEntry(entries[0], firstDirectory));
    assert(archive.extractEntry(entries[1], secondDirectory));
    assert(readText(buildPath(firstDirectory, "same.txt")) == "first occurrence");
    assert(readText(buildPath(secondDirectory, "same.txt")) == "second occurrence");
}

@("zip extraction treats option-like member names as files")
unittest
{
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.process : execute, executeShell;
    import std.uuid : randomUUID;

    if (executeShell("command -v zip").status != 0)
        return;
    const auto root = buildPath(tempDir(), "zip-option-member-"
        ~ randomUUID().toString());
    const auto source = buildPath(root, "source", "-d");
    const auto archivePath = buildPath(root, "option.zip");
    const auto output = buildPath(root, "output");
    mkdirRecurse(buildPath(root, "source"));
    mkdirRecurse(output);
    write(source, "payload");
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);

    const auto created = execute(["zip", "-q", "-j", archivePath, source]);
    assert(created.status == 0, created.output);
    auto archive = new FileArchiveZip(archivePath);
    assert(archive.extractEntry("-d", output));
    assert(exists(buildPath(output, "-d")));
}

@("zip extraction does not expand wildcard member names")
unittest
{
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.process : execute, executeShell;
    import std.uuid : randomUUID;

    if (executeShell("command -v python3").status != 0)
        return;
    const auto root = buildPath(tempDir(), "zip-wildcard-member-"
        ~ randomUUID().toString());
    const auto archivePath = buildPath(root, "wildcard.zip");
    const auto output = buildPath(root, "output");
    mkdirRecurse(root);
    mkdirRecurse(output);
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);

    const auto createScript = "import sys, zipfile; z=zipfile.ZipFile(sys.argv[1], 'w'); "
        ~ "z.writestr('foo*', 'literal star'); z.writestr('foo1', 'other'); z.close()";
    const auto created = execute(["python3", "-c", createScript, archivePath]);
    assert(created.status == 0, created.output);
    auto archive = new FileArchiveZip(archivePath);
    ArchiveEntryDescriptor target;
    bool found;
    foreach (entry; archive.getEntryDescriptors())
        if (entry.name == "foo*")
        {
            target = entry;
            found = true;
        }
    assert(found);
    assert(archive.extractEntry(target, output));
    assert(exists(buildPath(output, "foo*")));
    assert(!exists(buildPath(output, "foo1")),
        "wildcard members must not extract sibling names");
}

@("zip descriptors expose shallow member metadata")
unittest
{
    import std.file : exists, getSize, mkdirRecurse, rmdirRecurse, tempDir,
        write;
    import std.path : buildPath;
    import std.process : execute, executeShell;
    import std.uuid : randomUUID;

    if (executeShell("command -v zip").status != 0)
        return;
    const root = buildPath(tempDir(), "zip-shallow-metadata-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);
    const payload = buildPath(root, "member with space.txt");
    write(payload, "payload-content");
    const archivePath = buildPath(root, "sample.zip");
    auto created = execute(["zip", "-q", "-j", archivePath, payload]);
    assert(created.status == 0, created.output);

    auto archive = new FileArchiveZip(archivePath);
    auto descriptors = archive.getEntryDescriptors();
    assert(descriptors.length == 1);
    assert(descriptors[0].name == "member with space.txt",
        descriptors[0].name);
    assert(descriptors[0].hasSize);
    assert(descriptors[0].size == getSize(payload));
    assert(descriptors[0].hasModifiedAt);
    assert(descriptors[0].modifiedAt.length >= 16,
        descriptors[0].modifiedAt);
}

@("zip bulk extraction writes all members")
unittest
{
    import std.file : exists, mkdirRecurse, readText, rmdirRecurse, tempDir,
        write;
    import std.path : buildPath;
    import std.process : execute, executeShell;
    import std.uuid : randomUUID;

    if (executeShell("command -v zip").status != 0)
        return;
    const root = buildPath(tempDir(), "zip-bulk-extract-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);
    write(buildPath(root, "first.txt"), "first");
    write(buildPath(root, "second.txt"), "second");
    const archivePath = buildPath(root, "bulk.zip");
    auto created = execute(["zip", "-q", "-j", archivePath,
        buildPath(root, "first.txt"), buildPath(root, "second.txt")]);
    assert(created.status == 0, created.output);

    const output = buildPath(root, "output");
    mkdirRecurse(output);
    auto archive = new FileArchiveZip(archivePath);
    assert(archive.extractAllTo(output));
    assert(readText(buildPath(output, "first.txt")) == "first");
    assert(readText(buildPath(output, "second.txt")) == "second");
}
