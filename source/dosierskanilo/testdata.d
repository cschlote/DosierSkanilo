/** Deterministic synthetic catalog data shared by tests and the fixture CLI.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
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

import dosierarkivo.archive : archivePathSeparator;

/// Layout version written into generated fixture manifests.
enum syntheticFixtureGeneratorVersion = 1;
/// Fixed POSIX timestamp in seconds used for all generated fixture timestamps.
enum long syntheticSourceDateEpoch = 1_577_934_246; // 2020-01-02T03:04:06Z

/** One completed generation bundle; `catalogRoot` contains only scan inputs. */
struct SyntheticCatalogFixture
{
    /// Absolute path of the generated bundle root.
    string bundlePath;
    /// Path of the `catalog` directory holding only scan inputs.
    string catalogRoot;
    /// Path of the sibling `manifest.json` describing the expected contents.
    string manifestPath;
    /// Parsed manifest value; callers treat it as a read-only description.
    JSONValue manifest;
}

/** Description of one regular file to create inside the catalog tree. */
private struct FileDefinition
{
    /// Path relative to the catalog root, using `/` separators.
    string path;
    /// Descriptive role recorded in the manifest.
    string role;
    /// Exact file content.
    ubyte[] data;
}

/** Description of one member stored inside a generated archive. */
private struct ArchiveMemberDefinition
{
    /// Member path as stored in the archive.
    string path;
    /// Descriptive role recorded in the manifest.
    string role;
    /// Exact uncompressed member content.
    ubyte[] data;
}

/** Description of one archive to generate, including its encoded bytes. */
private struct ArchiveDefinition
{
    /// Path relative to the catalog root, using `/` separators.
    string path;
    /// Archive format identifier, for example `zip` or `tar`.
    string format;
    /// Members the archive is expected to contain.
    ArchiveMemberDefinition[] members;
    /// Encoded archive file content.
    ubyte[] data;
}

/** Lifecycle of the single-flight fixture builder. */
private enum FixtureSetupState
{
    /// No build has been attempted yet.
    uninitialized,
    /// A builder is running; other callers wait for it to finish.
    building,
    /// A fixture was published and can be shared.
    ready,
    /// The builder failed and its error is retained.
    failed
}

/** Thread-safe single-flight initializer shared by the helper and its tests. */
private class FixtureGate
{
    /// Protects the setup state, published fixture, and counters.
    private Mutex mutex;
    /// Signals waiting callers when the state changes.
    private Condition condition;
    /// Current single-flight setup state.
    private FixtureSetupState state;
    /// Published fixture value once the state is `ready`.
    private SyntheticCatalogFixture fixture;
    /// Message retained from a failed build.
    private string failureMessage;
    /// Number of successful builder invocations.
    private size_t buildCount;

    /** Create an empty gate with no fixture built yet. */
    this()
    {
        mutex = new Mutex();
        condition = new Condition(mutex);
    }

    /** Return the shared fixture, building it once on first use.
     *
     * Concurrent callers block until the first builder finishes and then share
     * its result. A failed build is retained and rethrown to later callers.
     *
     * Params:
     *     builder = Generator invoked at most once to create the fixture.
     * Returns: The published fixture value.
     * Throws: `Exception` when the builder throws or a previous build failed.
     */
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

    /** Report how many builders have completed successfully.
     *
     * Returns: The number of successful builds; zero before the first one.
     */
    size_t successfulBuildCount()
    {
        synchronized (mutex)
            return buildCount;
    }
}

/// Process-wide gate coordinating the immutable test fixture build.
private __gshared FixtureGate fixtureGate;

/** Initialize the process-wide fixture gate without touching the filesystem. */
shared static this()
{
    fixtureGate = new FixtureGate();
}

/** Generate or reuse one synthetic fixture bundle at `outputPath`.
 *
 * The bundle contains `catalog/` and a sibling `manifest.json`. Existing output
 * is reused only when its manifest and generated filesystem contents validate;
 * replacement of an invalid or unrelated directory requires `replaceExisting`.
 *
 * Params:
 *     outputPath = Bundle directory to generate or reuse.
 *     replaceExisting = Replace an existing output directory that does not
 *         match the generated fixture.
 *     updateExpectedManifest = Skip comparison against the checked-in golden
 *         manifest, for intentional generator changes.
 * Returns: The generated or reused fixture describing the bundle.
 * Throws: `Exception` when the golden manifest is missing or differs, the
 *     existing output cannot be reused, or generation/verification fails.
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
 *
 * Returns: The shared fixture with a freshly parsed manifest.
 * Throws: `Exception` when generation fails or the result differs from the
 *     checked-in golden manifest.
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

/** Copy the immutable generated catalog into a private mutable test directory.
 *
 * Params:
 *     destination = Directory to create and populate; it must not exist yet.
 * Returns: The normalized absolute path of the populated destination.
 * Throws: `Exception` when the destination already exists or the copy fails.
 */
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

/** Number of fixture builds performed by the process-local single-flight helper.
 *
 * Returns: The count of successful builds; zero before the first build.
 */
size_t syntheticFixtureBuildCount()
{
    return fixtureGate.successfulBuildCount();
}

/** A test-source SHA1 in lower-case hex, matching the backend's identity digest.
 *
 * Params:
 *     data = Bytes to hash.
 * Returns: 40 lower-case hexadecimal characters.
 */
string syntheticSha1Hex(const(ubyte)[] data)
{
    auto digest = new SHA1();
    digest.put(data);
    auto result = toHexString!(LetterCase.lower)(digest.finish());
    return result.idup;
}

/** Return the fixed UTC timestamp assigned to every generated file.
 *
 * Returns: 2020-01-02T03:04:06Z as a `SysTime`, keeping fixtures reproducible.
 */
private SysTime fixedFixtureTime()
{
    return SysTime(DateTime(2020, 1, 2, 3, 4, 6), UTC());
}

/** Copy a string's UTF-8 bytes into a mutable byte array.
 *
 * Params:
 *     value = Text whose bytes are copied.
 * Returns: A newly allocated byte array containing the string's code units.
 */
private ubyte[] bytes(string value)
{
    return cast(ubyte[]) value.dup;
}

/** Append a string's UTF-8 bytes to a byte buffer.
 *
 * Params:
 *     data = Buffer that is extended in place.
 *     value = Text appended to the buffer.
 */
private void appendText(ref ubyte[] data, string value)
{
    data ~= bytes(value);
}

/** Append the low bytes of an integer in little-endian order.
 *
 * Params:
 *     data = Buffer that is extended in place.
 *     value = Value whose bytes are appended.
 *     count = Number of low-order bytes to append; must not exceed four.
 */
private void appendLittleEndian(ref ubyte[] data, uint value, size_t count)
{
    foreach (index; 0 .. count)
        data ~= cast(ubyte) (value >> (index * 8));
}

/** Build a minimal deterministic PCM WAV file.
 *
 * Returns: A mono 8 kHz, 16-bit PCM WAV containing 16 silent samples.
 */
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

/** Build a minimal deterministic 24-bit bitmap image.
 *
 * Returns: A 2x2 BMP with four fixed colored pixels and padded row stride.
 */
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

/** Build a deterministic single-file torrent for a WAV payload.
 *
 * Params:
 *     wave = Complete payload whose SHA1 becomes the torrent piece hash.
 * Returns: Bencoded torrent data describing `tone.wav`.
 */
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

/** Build a deterministic torrent describing two files.
 *
 * The text and wave payloads are concatenated in that order to compute the
 * piece hash.
 *
 * Params:
 *     text = Content of `alpha.txt`.
 *     wave = Content of `nested/tone.wav`.
 * Returns: Bencoded multi-file torrent data.
 */
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

/** Encode archive members as a deterministic ZIP archive.
 *
 * Members are stored uncompressed with the fixed fixture timestamp.
 *
 * Params:
 *     members = Member definitions to add in order.
 * Returns: The encoded ZIP file content.
 */
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

/** Format an unsigned integer as an octal digit string.
 *
 * Params:
 *     value = Value to format.
 * Returns: Octal digits without a prefix; `0` for a zero value.
 */
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

/** Write text into a fixed-width TAR header field.
 *
 * Params:
 *     header = TAR header block being filled in.
 *     offset = Byte offset of the field.
 *     width = Field width in bytes.
 *     value = Text to copy; must fit within `width`.
 * Throws: `Exception` when the value is longer than the field.
 */
private void setTarText(ref ubyte[512] header, size_t offset, size_t width,
    string value)
{
    enforce(value.length <= width, "TAR field too long: " ~ value);
    foreach (index, character; value)
        header[offset + index] = cast(ubyte) character;
}

/** Write an octal number into a fixed-width TAR header field.
 *
 * The field is zero-padded, except for the final NUL terminator.
 *
 * Params:
 *     header = TAR header block being filled in.
 *     offset = Byte offset of the field.
 *     width = Field width in bytes, including the terminator.
 *     value = Value to encode.
 * Throws: `Exception` when the digits do not fit in the field.
 */
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

/** Encode archive members as a deterministic POSIX TAR archive.
 *
 * Headers use the fixed fixture timestamp and a computed checksum, and every
 * payload is padded to the next 512-byte boundary.
 *
 * Params:
 *     members = Member definitions to add in order.
 * Returns: The encoded TAR file content.
 */
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

/** Describe the single member stored in the nested ZIP fixture.
 *
 * Returns: One member definition for `deep/readme.txt`.
 */
private ArchiveMemberDefinition[] innerZipMembers()
{
    return [
        ArchiveMemberDefinition("deep/readme.txt", "nested-archive-member",
            bytes("nested synthetic archive member\n"))
    ];
}

/** Define the ZIP and TAR archives included in the synthetic catalog.
 *
 * Returns: Archive definitions with members and encoded file content, in
 *     deterministic order.
 */
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

/** Define all regular files in the synthetic catalog, including archives.
 *
 * Returns: File definitions sorted by ascending path.
 */
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

/** Convert a string list into a JSON array value.
 *
 * Params:
 *     values = Strings to convert, preserving their order.
 * Returns: A JSON array of string values.
 */
private JSONValue jsonStringArray(string[] values)
{
    JSONValue[] items;
    foreach (value; values)
        items ~= JSONValue(value);
    return JSONValue(items);
}

/** Build the manifest entry for one generated regular file.
 *
 * Params:
 *     file = File definition to describe.
 * Returns: JSON object with path, role, size, SHA-256, and modification time.
 */
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

/** Build the manifest entry for one generated archive.
 *
 * Params:
 *     archive = Archive definition to describe.
 * Returns: JSON object with path, format, size, SHA-256, and member entries.
 */
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

/** Build the complete fixture manifest from its inputs.
 *
 * Params:
 *     files = Regular files expected in the catalog.
 *     directories = Directory paths expected in the catalog.
 *     archives = Archives expected in the catalog.
 * Returns: JSON manifest with file, archive, duplicate-group, and count data.
 */
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
                ~ archive.path ~ archivePathSeparator() ~ member.path;
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

/** Compute the lower-case hexadecimal SHA-256 digest of a byte range.
 *
 * Params:
 *     data = Bytes to hash.
 * Returns: 64 hexadecimal characters.
 */
private string sha256Hex(const(ubyte)[] data)
{
    auto digest = new SHA256();
    digest.put(data);
    auto result = toHexString!(LetterCase.lower)(digest.finish());
    return result.idup;
}

/** Render a manifest as pretty-printed JSON text for file output.
 *
 * Params:
 *     manifest = Manifest value to serialize.
 * Returns: Indented JSON followed by a single trailing newline.
 */
private string manifestText(JSONValue manifest)
{
    return manifest.toPrettyString ~ "\n";
}

/** Verify that a catalog directory exactly matches the generated definitions.
 *
 * The check covers the directory/file set, file sizes and SHA-256 digests, and
 * the fixed modification time of every file. Paths escaping the root fail.
 *
 * Params:
 *     catalogRoot = Directory to inspect.
 *     files = Expected regular files.
 *     directories = Expected directory paths.
 * Returns: `true` when the tree is present and matches exactly.
 */
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

/** Report whether any path component starts with a dot.
 *
 * Params:
 *     relativePath = Slash-separated path relative to the catalog root.
 * Returns: `true` when at least one component is dot-prefixed.
 */
private bool isHiddenPath(string relativePath)
{
    foreach (part; relativePath.split("/"))
        if (part.startsWith("."))
            return true;
    return false;
}

/** Derive the sorted list of directories implied by the generated files.
 *
 * All parent directories are included, plus the explicit `empty-directory`.
 *
 * Params:
 *     files = Regular file definitions whose paths imply directories.
 * Returns: Sorted slash-separated directory paths.
 */
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
        if (failedBuilderCalls != 0)
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
