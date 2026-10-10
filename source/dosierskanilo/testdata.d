/** Deterministic synthetic catalog data shared by tests and the fixture CLI. */
module dosierskanilo.testdata;

import core.sync.condition : Condition;
import core.sync.mutex : Mutex;

import std.algorithm.mutation : reverse;
import std.algorithm.searching : canFind;
import std.algorithm.sorting : sort;
import std.conv : to;
import std.datetime : DateTime;
import std.datetime.systime : SysTime;
import std.datetime.timezone : UTC;
import std.digest : LetterCase, toHexString;
import std.digest.sha : SHA1, SHA256;
import std.exception : enforce;
import std.file : copy, dirEntries, exists, getSize, isDir, isFile, mkdirRecurse,
    getTimes, read, readText, rename, rmdirRecurse, setTimes, SpanMode, write;
import std.json : JSONValue, parseJSON;
import std.path : absolutePath, baseName, buildNormalizedPath, buildPath, dirName,
    dirSeparator;
import std.process : thisProcessID;
import std.string : split, startsWith;
import std.uuid : randomUUID;
import std.zip : ArchiveMember, CompressionMethod, ZipArchive;

enum syntheticFixtureGeneratorVersion = 1;
enum long syntheticSourceDateEpoch = 1_577_934_246; // 2020-01-02T03:04:06Z

/** One completed generation bundle; `catalogRoot` contains only scan inputs. */
struct SyntheticCatalogFixture
{
    string bundlePath;
    string catalogRoot;
    string manifestPath;
    JSONValue manifest;
}

private struct FileDefinition
{
    string path;
    string role;
    ubyte[] data;
}

private struct ArchiveMemberDefinition
{
    string path;
    string role;
    ubyte[] data;
}

private struct ArchiveDefinition
{
    string path;
    string format;
    ArchiveMemberDefinition[] members;
    ubyte[] data;
}

private enum FixtureSetupState
{
    uninitialized,
    building,
    ready,
    failed
}

/** Thread-safe single-flight initializer shared by the helper and its tests. */
private class FixtureGate
{
    private Mutex mutex;
    private Condition condition;
    private FixtureSetupState state;
    private SyntheticCatalogFixture fixture;
    private string failureMessage;
    private size_t buildCount;

    this()
    {
        mutex = new Mutex();
        condition = new Condition(mutex);
    }

    SyntheticCatalogFixture get(SyntheticCatalogFixture delegate() builder)
    {
        bool shouldBuild;
        synchronized (mutex)
        {
            while (state == FixtureSetupState.building)
                condition.wait();
            final switch (state)
            {
            case FixtureSetupState.uninitialized:
                state = FixtureSetupState.building;
                shouldBuild = true;
                break;
            case FixtureSetupState.building:
                assert(false, "wait loop must consume the building state");
            case FixtureSetupState.ready:
                return fixture;
            case FixtureSetupState.failed:
                throw new Exception("Synthetic fixture setup failed: "
                    ~ failureMessage);
            }
        }
        assert(shouldBuild);

        try
        {
            auto completed = builder();
            synchronized (mutex)
            {
                fixture = completed;
                ++buildCount;
                state = FixtureSetupState.ready;
                condition.notifyAll();
            }
            return completed;
        }
        catch (Throwable failure)
        {
            synchronized (mutex)
            {
                failureMessage = failure.msg;
                state = FixtureSetupState.failed;
                condition.notifyAll();
            }
            throw new Exception("Synthetic fixture setup failed: "
                ~ failure.msg);
        }
    }

    size_t successfulBuildCount()
    {
        synchronized (mutex)
            return buildCount;
    }
}

private __gshared FixtureGate fixtureGate;

shared static this()
{
    fixtureGate = new FixtureGate();
}

/** Generate or reuse one synthetic fixture bundle at `outputPath`.
 *
 * The bundle contains `catalog/` and a sibling `manifest.json`. Existing output
 * is reused only when its manifest and generated filesystem contents validate;
 * replacement of an invalid or unrelated directory requires `replaceExisting`.
 */
SyntheticCatalogFixture generateSyntheticCatalog(string outputPath,
    bool replaceExisting = false, bool updateExpectedManifest = false)
{
    auto definitions = buildFileDefinitions();
    auto archives = buildArchiveDefinitions();
    auto directories = buildDirectoryList(definitions);
    auto expectedManifest = buildManifest(definitions, directories, archives);
    if (!updateExpectedManifest)
    {
        auto goldenPath = buildPath("test", "fixtures", "synthetic",
            "catalog-manifest.json");
        enforce(exists(goldenPath), "Missing synthetic golden manifest: " ~ goldenPath);
        enforce(parseJSON(readText(goldenPath)) == expectedManifest,
            "Generated synthetic manifest differs from " ~ goldenPath
            ~ "; inspect it and use --update-manifest explicitly if intended.");
    }
    auto normalizedOutput = buildNormalizedPath(absolutePath(outputPath));
    auto manifestPath = buildPath(normalizedOutput, "manifest.json");
    auto catalogRoot = buildPath(normalizedOutput, "catalog");

    enforce(!exists(normalizedOutput) || isDir(normalizedOutput),
        "Fixture output exists but is not a directory: " ~ normalizedOutput);
    if (exists(normalizedOutput) && !replaceExisting)
    {
        if (exists(manifestPath))
        {
            auto existingManifest = parseJSON(readText(manifestPath));
            if (existingManifest == expectedManifest
                && verifyCatalogTree(catalogRoot, definitions, directories))
                return SyntheticCatalogFixture(normalizedOutput, catalogRoot,
                    manifestPath, existingManifest);
        }
        throw new Exception("Fixture output already exists but does not match this "
            ~ "generator version; choose another --output path or pass --replace.");
    }

    auto outputParent = dirName(normalizedOutput);
    mkdirRecurse(outputParent);
    auto stagePath = buildPath(outputParent, ".synthetic-stage-"
        ~ thisProcessID.to!string ~ "-" ~ randomUUID().toString());
    auto stageCatalogRoot = buildPath(stagePath, "catalog");
    mkdirRecurse(stageCatalogRoot);
    scope (exit)
    {
        if (exists(stagePath))
            rmdirRecurse(stagePath);
    }

    foreach (directory; directories)
        mkdirRecurse(buildPath(stageCatalogRoot, directory));
    foreach (file; definitions)
    {
        auto filePath = buildPath(stageCatalogRoot, file.path);
        mkdirRecurse(dirName(filePath));
        write(filePath, file.data);
        setTimes(filePath, fixedFixtureTime(), fixedFixtureTime());
    }
    auto stagedManifestPath = buildPath(stagePath, "manifest.json");
    write(stagedManifestPath, manifestText(expectedManifest));
    enforce(verifyCatalogTree(stageCatalogRoot, definitions, directories),
        "Generated synthetic catalog failed its filesystem verification.");

    string oldPath;
    if (exists(normalizedOutput))
    {
        oldPath = normalizedOutput ~ ".previous-" ~ randomUUID().toString();
        rename(normalizedOutput, oldPath);
    }
    try
    {
        rename(stagePath, normalizedOutput);
    }
    catch (Exception ex)
    {
        if (oldPath.length > 0 && exists(oldPath))
            rename(oldPath, normalizedOutput);
        throw ex;
    }
    if (oldPath.length > 0 && exists(oldPath))
        rmdirRecurse(oldPath);
    return SyntheticCatalogFixture(normalizedOutput,
        buildPath(normalizedOutput, "catalog"),
        buildPath(normalizedOutput, "manifest.json"), expectedManifest);
}

/**
 * Lazily generate the immutable test seed exactly once in this process.
 * Calls from concurrent `silly` workers wait for the first generator and share
 * its published catalog path; no filesystem work happens in the static ctor.
 */
SyntheticCatalogFixture ensureSyntheticTestCatalog()
{
    auto fixture = fixtureGate.get({
        auto outputPath = buildPath("build", "test-data",
            "unit-" ~ thisProcessID.to!string, "synthetic-catalog");
        auto fixture = generateSyntheticCatalog(outputPath, true);
        auto goldenPath = buildPath("test", "fixtures", "synthetic",
            "catalog-manifest.json");
        enforce(exists(goldenPath), "Missing synthetic golden manifest: " ~ goldenPath);
        auto golden = parseJSON(readText(goldenPath));
        enforce(fixture.manifest == golden,
            "Generated synthetic manifest differs from " ~ goldenPath
            ~ "; inspect it and explicitly update the golden if intended.");
        return fixture;
    });
    fixture.manifest = parseJSON(readText(fixture.manifestPath));
    return fixture;
}

/** Copy the immutable generated catalog into a private mutable test directory. */
string copySyntheticCatalogForTest(string destination)
{
    auto fixture = ensureSyntheticTestCatalog();
    auto normalizedRoot = buildNormalizedPath(fixture.catalogRoot);
    auto normalizedDestination = buildNormalizedPath(absolutePath(destination));
    enforce(!exists(normalizedDestination),
        "Synthetic test copy destination already exists: " ~ normalizedDestination);
    mkdirRecurse(normalizedDestination);
    try
    {
        foreach (entry; dirEntries(normalizedRoot, SpanMode.depth))
        {
            auto normalizedEntry = buildNormalizedPath(entry.name);
            auto prefix = normalizedRoot ~ dirSeparator;
            enforce(normalizedEntry.startsWith(prefix),
                "Generated fixture entry escaped its root: " ~ normalizedEntry);
            auto relative = normalizedEntry[prefix.length .. $];
            auto target = buildPath(normalizedDestination, relative);
            if (isDir(entry.name))
                mkdirRecurse(target);
            else if (isFile(entry.name))
            {
                mkdirRecurse(dirName(target));
                copy(entry.name, target);
            }
        }
        return normalizedDestination;
    }
    catch (Throwable failure)
    {
        if (exists(normalizedDestination))
            rmdirRecurse(normalizedDestination);
        throw new Exception("Could not copy synthetic catalog for test: "
            ~ failure.msg);
    }
}

/** Number of fixture builds performed by the process-local single-flight helper. */
size_t syntheticFixtureBuildCount()
{
    return fixtureGate.successfulBuildCount();
}

/** A test-source SHA1 in lower-case hex, matching the backend's identity digest. */
string syntheticSha1Hex(const(ubyte)[] data)
{
    auto digest = new SHA1();
    digest.put(data);
    auto result = toHexString!(LetterCase.lower)(digest.finish());
    return result.idup;
}

private SysTime fixedFixtureTime()
{
    return SysTime(DateTime(2020, 1, 2, 3, 4, 6), UTC());
}

private ubyte[] bytes(string value)
{
    return cast(ubyte[]) value.dup;
}

private void appendText(ref ubyte[] data, string value)
{
    data ~= bytes(value);
}

private void appendLittleEndian(ref ubyte[] data, uint value, size_t count)
{
    foreach (index; 0 .. count)
        data ~= cast(ubyte) (value >> (index * 8));
}

private ubyte[] syntheticWave()
{
    enum sampleCount = 16;
    enum sampleBytes = sampleCount * 2;
    ubyte[] data;
    appendText(data, "RIFF");
    appendLittleEndian(data, 36 + sampleBytes, 4);
    appendText(data, "WAVEfmt ");
    appendLittleEndian(data, 16, 4); // PCM fmt chunk size
    appendLittleEndian(data, 1, 2); // PCM
    appendLittleEndian(data, 1, 2); // mono
    appendLittleEndian(data, 8_000, 4);
    appendLittleEndian(data, 16_000, 4);
    appendLittleEndian(data, 2, 2);
    appendLittleEndian(data, 16, 2);
    appendText(data, "data");
    appendLittleEndian(data, sampleBytes, 4);
    data.length += sampleBytes; // deterministic silence
    return data;
}

private ubyte[] syntheticBitmap()
{
    enum width = 2;
    enum height = 2;
    enum rowSize = 8; // 24-bit rows are padded to a four-byte boundary.
    enum pixelBytes = rowSize * height;
    ubyte[] data;
    appendText(data, "BM");
    appendLittleEndian(data, 54 + pixelBytes, 4);
    appendLittleEndian(data, 0, 4);
    appendLittleEndian(data, 54, 4);
    appendLittleEndian(data, 40, 4);
    appendLittleEndian(data, width, 4);
    appendLittleEndian(data, height, 4);
    appendLittleEndian(data, 1, 2);
    appendLittleEndian(data, 24, 2);
    appendLittleEndian(data, 0, 4);
    appendLittleEndian(data, pixelBytes, 4);
    appendLittleEndian(data, 2_835, 4);
    appendLittleEndian(data, 2_835, 4);
    appendLittleEndian(data, 0, 4);
    appendLittleEndian(data, 0, 4);
    foreach (value; [0x22, 0x44, 0x66, 0, 0x88, 0xAA, 0xCC, 0,
        0xEE, 0xCC, 0xAA, 0, 0x66, 0x44, 0x22, 0])
        data ~= cast(ubyte) value;
    return data;
}

private ubyte[] syntheticTorrent(ubyte[] wave)
{
    auto digest = new SHA1();
    digest.put(wave);
    auto payloadHash = digest.finish();
    ubyte[] torrent;
    appendText(torrent, "d4:infod6:lengthi" ~ wave.length.to!string
        ~ "e4:name8:tone.wav12:piece lengthi16384e6:pieces20:");
    torrent ~= payloadHash[];
    appendText(torrent, "ee");
    return torrent;
}

private ubyte[] syntheticMultiFileTorrent(ubyte[] text, ubyte[] wave)
{
    ubyte[] joined = text.dup;
    joined ~= wave;
    auto digest = new SHA1();
    digest.put(joined);
    auto pieceHash = digest.finish();

    ubyte[] torrent;
    appendText(torrent, "d4:infod5:filesl");
    appendText(torrent, "d6:lengthi" ~ text.length.to!string ~ "e4:pathl");
    appendText(torrent, "9:alpha.txt");
    appendText(torrent, "ee");
    appendText(torrent, "d6:lengthi" ~ wave.length.to!string ~ "e4:pathl");
    appendText(torrent, "6:nested8:tone.wav");
    appendText(torrent, "ee");
    appendText(torrent, "e4:name19:synthetic-multifile12:piece lengthi16384e6:pieces20:");
    torrent ~= pieceHash[];
    appendText(torrent, "ee");
    return torrent;
}

private ubyte[] buildZip(ArchiveMemberDefinition[] members)
{
    auto zip = new ZipArchive();
    foreach (index, definition; members)
    {
        auto member = new ArchiveMember();
        member.name = definition.path;
        member.expandedData = definition.data.dup;
        member.compressionMethod = CompressionMethod.none;
        member.time = fixedFixtureTime();
        member.index = cast(uint) index;
        zip.addMember(member);
    }
    return cast(ubyte[]) zip.build();
}

private string octalDigits(ulong value)
{
    char[] digits;
    do
    {
        digits ~= cast(char) ('0' + (value & 7));
        value >>= 3;
    }
    while (value > 0);
    digits.reverse;
    return digits.idup;
}

private void setTarText(ref ubyte[512] header, size_t offset, size_t width,
    string value)
{
    enforce(value.length <= width, "TAR field too long: " ~ value);
    foreach (index, character; value)
        header[offset + index] = cast(ubyte) character;
}

private void setTarOctal(ref ubyte[512] header, size_t offset, size_t width,
    ulong value)
{
    auto digits = octalDigits(value);
    enforce(digits.length <= width - 1, "TAR numeric field overflow.");
    foreach (index; 0 .. width)
        header[offset + index] = cast(ubyte) '0';
    auto start = offset + width - digits.length - 1;
    foreach (index, digit; digits)
        header[start + index] = cast(ubyte) digit;
    header[offset + width - 1] = 0;
}

private ubyte[] buildTar(ArchiveMemberDefinition[] members)
{
    ubyte[] archive;
    foreach (member; members)
    {
        ubyte[512] header;
        setTarText(header, 0, 100, member.path);
        setTarOctal(header, 100, 8, 0x1A4); // 0644
        setTarOctal(header, 108, 8, 0);
        setTarOctal(header, 116, 8, 0);
        setTarOctal(header, 124, 12, member.data.length);
        setTarOctal(header, 136, 12, syntheticSourceDateEpoch);
        foreach (index; 148 .. 156)
            header[index] = ' ';
        header[156] = '0';
        setTarText(header, 257, 6, "ustar");
        setTarText(header, 263, 2, "00");
        ulong checksum;
        foreach (value; header)
            checksum += value;
        auto checksumDigits = octalDigits(checksum);
        enforce(checksumDigits.length <= 6, "TAR checksum field overflow.");
        auto checksumStart = 148 + 6 - checksumDigits.length;
        foreach (index, digit; checksumDigits)
            header[checksumStart + index] = cast(ubyte) digit;
        header[154] = 0;
        header[155] = ' ';
        archive ~= header[];
        archive ~= member.data;
        auto padding = (512 - (member.data.length % 512)) % 512;
        archive.length += padding;
    }
    archive.length += 1024; // End-of-archive marker.
    return archive;
}

private ArchiveMemberDefinition[] innerZipMembers()
{
    return [
        ArchiveMemberDefinition("deep/readme.txt", "nested-archive-member",
            bytes("nested synthetic archive member\n"))
    ];
}

private ArchiveDefinition[] buildArchiveDefinitions()
{
    auto sharedText = bytes("synthetic duplicate payload\n");
    auto wave = syntheticWave();
    auto innerZip = buildZip(innerZipMembers());
    ArchiveMemberDefinition[] zipMembers = [
        ArchiveMemberDefinition("payload/copy.txt", "duplicate-of-filesystem-payload",
            sharedText.dup),
        ArchiveMemberDefinition("nested/unique.txt", "unique-zip-member",
            bytes("unique ZIP member data\n")),
        ArchiveMemberDefinition("left/shared.txt", "duplicate-basename-left",
            bytes("left member\n")),
        ArchiveMemberDefinition("right/shared.txt", "duplicate-basename-right",
            bytes("right member\n")),
        ArchiveMemberDefinition("empty/zero.bin", "empty-zip-member", []),
        ArchiveMemberDefinition("media/tone.wav", "same-content-as-filesystem-wave",
            wave.dup),
        ArchiveMemberDefinition("nested.zip", "nested-archive", innerZip)
    ];
    ArchiveMemberDefinition[] tarMembers = [
        ArchiveMemberDefinition("payload/copy.txt", "duplicate-of-filesystem-payload",
            sharedText.dup),
        ArchiveMemberDefinition("tar/unique.txt", "unique-tar-member",
            bytes("unique TAR member data\n")),
        ArchiveMemberDefinition("empty.bin", "empty-tar-member", [])
    ];
    return [
        ArchiveDefinition("archives/sample.zip", "zip", zipMembers,
            buildZip(zipMembers)),
        ArchiveDefinition("archives/sample.tar", "tar", tarMembers,
            buildTar(tarMembers)),
        ArchiveDefinition("archives/nested.zip", "zip", innerZipMembers(),
            innerZip)
    ];
}

private FileDefinition[] buildFileDefinitions()
{
    auto sharedText = bytes("synthetic duplicate payload\n");
    auto wave = syntheticWave();
    auto archives = buildArchiveDefinitions();
    FileDefinition[] files = [
        FileDefinition("alpha/original.txt", "duplicate-source", sharedText.dup),
        FileDefinition("copies/copy.txt", "duplicate-copy", sharedText.dup),
        FileDefinition("same-size/different.txt", "same-size-different-content",
            bytes("synthetic duplicate payloae\n")),
        FileDefinition("empty/zero.bin", "empty-file", []),
        FileDefinition("unicode/café.txt", "utf8-text", bytes("synthetic UTF-8 café\n")),
        FileDefinition(".hidden/secret.txt", "hidden-file", bytes("hidden fixture\n")),
        FileDefinition("media/tone.wav", "generated-wave", wave),
        FileDefinition("images/sample.bmp", "generated-bitmap", syntheticBitmap()),
        FileDefinition("torrent/single-file.torrent", "generated-single-file-torrent",
            syntheticTorrent(wave)),
        FileDefinition("torrent/multi-file.torrent", "generated-multi-file-torrent",
            syntheticMultiFileTorrent(sharedText, wave))
    ];
    foreach (archive; archives)
        files ~= FileDefinition(archive.path, "archive-container:" ~ archive.format,
            archive.data);
    files.sort!((left, right) => left.path < right.path);
    return files;
}

private JSONValue jsonStringArray(string[] values)
{
    JSONValue[] items;
    foreach (value; values)
        items ~= JSONValue(value);
    return JSONValue(items);
}

private JSONValue jsonFile(FileDefinition file)
{
    JSONValue[string] value;
    value["path"] = JSONValue(file.path);
    value["role"] = JSONValue(file.role);
    value["size"] = JSONValue(cast(ulong) file.data.length);
    value["sha256"] = JSONValue(sha256Hex(file.data));
    value["modifiedAt"] = JSONValue(fixedFixtureTime().toISOExtString);
    return JSONValue(value);
}

private JSONValue jsonArchive(ArchiveDefinition archive)
{
    JSONValue[] entries;
    foreach (member; archive.members)
    {
        JSONValue[string] entry;
        entry["path"] = JSONValue(member.path);
        entry["role"] = JSONValue(member.role);
        entry["size"] = JSONValue(cast(ulong) member.data.length);
        entry["sha256"] = JSONValue(sha256Hex(member.data));
        entries ~= JSONValue(entry);
    }
    JSONValue[string] value;
    value["path"] = JSONValue(archive.path);
    value["format"] = JSONValue(archive.format);
    value["size"] = JSONValue(cast(ulong) archive.data.length);
    value["sha256"] = JSONValue(sha256Hex(archive.data));
    value["entries"] = JSONValue(entries);
    return JSONValue(value);
}

private JSONValue buildManifest(FileDefinition[] files, string[] directories,
    ArchiveDefinition[] archives)
{
    JSONValue[] fileValues;
    string[][string] locationsByChecksum;
    size_t hiddenCount;
    foreach (file; files)
    {
        fileValues ~= jsonFile(file);
        locationsByChecksum[sha256Hex(file.data)] ~= "file:" ~ file.path;
        if (isHiddenPath(file.path))
            hiddenCount++;
    }
    JSONValue[] archiveValues;
    foreach (archive; archives)
    {
        archiveValues ~= jsonArchive(archive);
        foreach (member; archive.members)
            locationsByChecksum[sha256Hex(member.data)] ~= "archive:"
                ~ archive.path ~ "!/" ~ member.path;
    }

    string[] checksums;
    foreach (checksum; locationsByChecksum.keys)
        checksums ~= checksum;
    checksums.sort;
    JSONValue[] duplicateGroups;
    foreach (checksum; checksums)
    {
        auto locations = locationsByChecksum[checksum];
        if (locations.length < 2)
            continue;
        locations.sort;
        JSONValue[string] group;
        group["sha256"] = JSONValue(checksum);
        group["locations"] = jsonStringArray(locations);
        duplicateGroups ~= JSONValue(group);
    }

    size_t archiveMemberCount;
    foreach (archive; archives)
        archiveMemberCount += archive.members.length;
    JSONValue[string] expected;
    expected["physicalFileCount"] = JSONValue(cast(ulong) files.length);
    expected["visiblePhysicalFileCount"] = JSONValue(cast(ulong)
        (files.length - hiddenCount));
    expected["hiddenPhysicalFileCount"] = JSONValue(cast(ulong) hiddenCount);
    expected["archiveCount"] = JSONValue(cast(ulong) archives.length);
    expected["archiveEntryCount"] = JSONValue(cast(ulong) archiveMemberCount);
    expected["duplicateContentGroupCount"] = JSONValue(
        cast(ulong) duplicateGroups.length);

    JSONValue[string] manifest;
    manifest["schemaVersion"] = JSONValue(1);
    manifest["generatorVersion"] = JSONValue(syntheticFixtureGeneratorVersion);
    manifest["sourceDateEpoch"] = JSONValue(syntheticSourceDateEpoch);
    manifest["directories"] = jsonStringArray(directories);
    manifest["files"] = JSONValue(fileValues);
    manifest["archives"] = JSONValue(archiveValues);
    manifest["duplicateContentGroups"] = JSONValue(duplicateGroups);
    manifest["expected"] = JSONValue(expected);
    JSONValue[] optionalFormats;
    foreach (format; ["rar", "7z"])
    {
        JSONValue[string] skipped;
        skipped["format"] = JSONValue(format);
        skipped["status"] = JSONValue("skipped");
        skipped["reason"] = JSONValue("optional format is outside the deterministic D baseline");
        optionalFormats ~= JSONValue(skipped);
    }
    manifest["optionalFormats"] = JSONValue(optionalFormats);
    return JSONValue(manifest);
}

private string sha256Hex(const(ubyte)[] data)
{
    auto digest = new SHA256();
    digest.put(data);
    auto result = toHexString!(LetterCase.lower)(digest.finish());
    return result.idup;
}

private string manifestText(JSONValue manifest)
{
    return manifest.toPrettyString ~ "\n";
}

private bool verifyCatalogTree(string catalogRoot, FileDefinition[] files,
    string[] directories)
{
    if (!exists(catalogRoot) || !isDir(catalogRoot))
        return false;
    string[] actualDirectories;
    string[] actualFiles;
    foreach (entry; dirEntries(catalogRoot, SpanMode.depth))
    {
        auto normalizedEntry = buildNormalizedPath(entry.name);
        auto prefix = buildNormalizedPath(catalogRoot) ~ dirSeparator;
        if (!normalizedEntry.startsWith(prefix))
            return false;
        auto relative = normalizedEntry[prefix.length .. $];
        if (isDir(entry.name))
            actualDirectories ~= relative;
        else if (isFile(entry.name))
            actualFiles ~= relative;
        else
            return false;
    }
    actualDirectories.sort;
    actualFiles.sort;
    auto expectedDirectories = directories.dup;
    expectedDirectories.sort;
    string[] expectedFiles;
    foreach (file; files)
        expectedFiles ~= file.path;
    expectedFiles.sort;
    if (actualDirectories != expectedDirectories || actualFiles != expectedFiles)
        return false;
    foreach (file; files)
    {
        auto path = buildPath(catalogRoot, file.path);
        if (!isFile(path) || getSize(path) != file.data.length)
            return false;
        if (sha256Hex(cast(ubyte[]) read(path)) != sha256Hex(file.data))
            return false;
        SysTime accessTime;
        SysTime modifiedTime;
        getTimes(path, accessTime, modifiedTime);
        if (modifiedTime != fixedFixtureTime())
            return false;
    }
    return true;
}

private bool isHiddenPath(string relativePath)
{
    foreach (part; relativePath.split("/"))
        if (part.startsWith("."))
            return true;
    return false;
}

private string[] buildDirectoryList(FileDefinition[] files)
{
    bool[string] seen;
    seen["empty-directory"] = true;
    foreach (file; files)
    {
        auto parts = file.path.split("/");
        string directory;
        foreach (part; parts[0 .. $ - 1])
        {
            directory = directory.length == 0 ? part : directory ~ "/" ~ part;
            seen[directory] = true;
        }
    }
    string[] directories;
    foreach (directory; seen.keys)
        directories ~= directory;
    directories.sort;
    return directories;
}

@("synthetic fixture initialization is single-flight for success and failure")
unittest
{
    import core.thread : Thread;
    import std.datetime : dur;

    enum callerCount = 8;
    auto gate = new FixtureGate();
    auto resultMutex = new Mutex();
    string[] roots;
    size_t builderCalls;
    auto builder = {
        ++builderCalls;
        Thread.sleep(dur!"msecs"(50));
        return SyntheticCatalogFixture("shared-bundle", "shared-catalog",
            "shared-manifest.json", JSONValue.init);
    };
    Thread[] workers;
    foreach (_; 0 .. callerCount)
        workers ~= new Thread({
            auto fixture = gate.get(builder);
            synchronized (resultMutex)
                roots ~= fixture.catalogRoot;
        });
    foreach (worker; workers)
        worker.start();
    foreach (worker; workers)
        worker.join();
    assert(roots.length == callerCount);
    foreach (root; roots)
        assert(root == "shared-catalog");
    assert(builderCalls == 1);
    assert(gate.successfulBuildCount() == 1);

    auto failedGate = new FixtureGate();
    auto failureMutex = new Mutex();
    string[] failures;
    size_t failedBuilderCalls;
    auto failingBuilder = {
        ++failedBuilderCalls;
        Thread.sleep(dur!"msecs"(50));
        throw new Exception("injected fixture failure");
        return SyntheticCatalogFixture.init;
    };
    workers.length = 0;
    foreach (_; 0 .. callerCount)
        workers ~= new Thread({
            try
                failedGate.get(failingBuilder);
            catch (Exception failure)
            {
                synchronized (failureMutex)
                    failures ~= failure.msg;
            }
        });
    foreach (worker; workers)
        worker.start();
    foreach (worker; workers)
        worker.join();
    assert(failures.length == callerCount);
    foreach (failure; failures)
        assert(failure == failures[0]);
    assert(failedBuilderCalls == 1);
    assert(failedGate.successfulBuildCount() == 0);
}

@("synthetic fixture matches its golden manifest and exact filesystem layout")
unittest
{
    import std.file : getTimes, readText;
    import std.path : buildPath;

    auto fixture = ensureSyntheticTestCatalog();
    auto goldenPath = buildPath("test", "fixtures", "synthetic",
        "catalog-manifest.json");
    auto golden = parseJSON(readText(goldenPath));
    assert(fixture.manifest == golden);
    auto definitions = buildFileDefinitions();
    auto directories = buildDirectoryList(definitions);
    assert(verifyCatalogTree(fixture.catalogRoot, definitions, directories));
    assert(syntheticFixtureBuildCount() == 1);
}

@("generator preserves unrelated output unless replacement is explicit")
unittest
{
    import std.file : exists, mkdirRecurse, readText, rmdirRecurse, tempDir, write;
    import std.path : buildPath;

    auto output = buildPath(tempDir(), "synthetic-output-policy-"
        ~ randomUUID().toString());
    mkdirRecurse(output);
    scope (exit)
        if (exists(output))
            rmdirRecurse(output);
    auto sentinel = buildPath(output, "keep.txt");
    write(sentinel, "unrelated content\n");

    bool refusedOverwrite;
    try
        generateSyntheticCatalog(output);
    catch (Exception)
        refusedOverwrite = true;
    assert(refusedOverwrite);
    assert(readText(sentinel) == "unrelated content\n");

    auto generated = generateSyntheticCatalog(output, true);
    assert(!exists(sentinel));
    auto firstManifestText = readText(generated.manifestPath);
    auto reused = generateSyntheticCatalog(output);
    assert(reused.manifest == generated.manifest);
    assert(readText(reused.manifestPath) == firstManifestText);
}

@("synthetic fixture archive entries match their generated manifest")
unittest
{
    import std.algorithm.sorting : sort;
    import std.file : exists, getcwd, mkdirRecurse, readText, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.process : execute;
    import dosierarkivo.factory : fileArchive;

    auto fixture = ensureSyntheticTestCatalog();
    bool unzipAvailable;
    try
        unzipAvailable = execute(["unzip", "-v"]).status == 0;
    catch (Exception)
        unzipAvailable = false;
    if (!unzipAvailable)
        return;

    auto archivePath = buildPath(fixture.catalogRoot, "archives", "sample.zip");
    auto archive = fileArchive(archivePath);
    auto entries = archive.getEntries();
    string[] expectedZipEntries = [
        "payload/copy.txt", "nested/unique.txt", "left/shared.txt",
        "right/shared.txt", "empty/zero.bin", "media/tone.wav", "nested.zip"
    ];
    entries.sort;
    expectedZipEntries.sort;
    assert(entries == expectedZipEntries, entries.to!string);

    auto nestedArchive = fileArchive(buildPath(fixture.catalogRoot, "archives",
        "nested.zip"));
    assert(nestedArchive.getEntries() == ["deep/readme.txt"]);

    auto extractRoot = buildPath(tempDir(), "synthetic-archive-extract-"
        ~ randomUUID().toString());
    mkdirRecurse(extractRoot);
    scope (exit)
        if (exists(extractRoot))
            rmdirRecurse(extractRoot);
    assert(archive.extractEntry("payload/copy.txt", extractRoot));
    assert(readText(buildPath(extractRoot, "payload", "copy.txt"))
        == "synthetic duplicate payload\n");

    bool tarAvailable;
    try
        tarAvailable = execute(["tar", "--version"]).status == 0;
    catch (Exception)
        tarAvailable = false;
    if (tarAvailable)
    {
        auto tar = fileArchive(buildPath(fixture.catalogRoot, "archives", "sample.tar"));
        auto tarEntries = tar.getEntries();
        string[] expectedTarEntries = ["payload/copy.txt", "tar/unique.txt", "empty.bin"];
        tarEntries.sort;
        expectedTarEntries.sort;
        assert(tarEntries == expectedTarEntries, tarEntries.to!string);
        assert(tar.extractEntry("payload/copy.txt", extractRoot));
        assert(readText(buildPath(extractRoot, "payload", "copy.txt"))
            == "synthetic duplicate payload\n");
    }
}
