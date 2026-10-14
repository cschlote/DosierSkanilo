/** Archive abstraction and extraction helpers.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierarkivo.archive;

import std.algorithm.searching : canFind, startsWith;
import std.array : join;
import std.string : toLower;

/** Raised when an archive operation needs a password or rejects the supplied one. */
class ArchivePasswordRequiredException : Exception
{
    this(string message)
    {
        super(message);
    }
}

/** Raised when an interactive password request is cancelled by the caller. */
class ArchivePasswordCancelledException : Exception
{
    this(string message)
    {
        super(message);
    }
}

/** Callback that requests a password; return false when the request is cancelled. */
alias ArchivePasswordCallback = bool delegate(string archivePath, string reason,
    out string password);

/** Whether external archive-tool output indicates a missing or rejected password. */
bool isArchivePasswordFailure(string output)
{
    auto message = output.toLower;
    return message.canFind("password") || message.canFind("encrypted")
        || message.canFind("passphrase");
}

/** Types of archives we support. */
enum ArchiveType
{
    unknown,
    zip,
    tar,
    rar,
    _7z
}

/** File extension for ZIP archives. */
enum ZIP_SUFFIX = ".zip";
/** File extension for TAR archives. */
enum TAR_SUFFIX = ".tar";
/** File extension for RAR archives. */
enum RAR_SUFFIX = ".rar";
/** File extension for 7z archives. */
enum _7Z_SUFFIX = ".7z";

/** Version of the normalized path/occurrence identity used by archive indexes. */
enum archiveEntryIdentityVersion = "path-occurrence-v1";
/** Version of the archive scan/index behavior, including recursive member indexing. */
enum archiveIndexVersion = "nested-index-v2";

/** One ordered archive member descriptor, independent of extracting its bytes. */
struct ArchiveEntryDescriptor
{
    size_t index; /// Position in the archive handler's current entry sequence.
    size_t occurrence; /// Zero-based occurrence among identical normalized paths.
    string name; /// Format-provided member name, unchanged for display/extraction.
    string relativePath; /// Normalized slash-separated path when safe.
    ulong size; /// Uncompressed size when supplied by the archive index.
    string modifiedAt; /// Archive timestamp when supplied without extraction.
    ubyte[] formatChecksum; /// Optional checksum exposed directly by the format.
    bool hasSize; /// Whether `size` came from archive metadata.
    bool hasModifiedAt; /// Whether `modifiedAt` came from archive metadata.
    bool isDirectory; /// True for an explicit directory entry.
    bool hasSafePath; /// False for absolute or traversal paths that cannot be indexed.
}

/** Normalize a member name without permitting absolute or traversal paths. */
string normalizeArchiveEntryPath(string name, out bool safe, out bool isDirectory)
{
    import std.string : replace, split;

    auto normalized = name.replace('\\', '/');
    isDirectory = normalized.length > 0 && normalized[$ - 1] == '/';
    safe = normalized.length > 0 && !normalized.startsWith("/")
        && !normalized.canFind('\0')
        && !(normalized.length >= 2 && normalized[1] == ':');
    if (!safe)
        return "";

    string[] components;
    foreach (component; normalized.split("/"))
    {
        if (component.length == 0 || component == ".")
            continue;
        if (component == "..")
        {
            safe = false;
            return "";
        }
        components ~= component;
    }
    return components.join("/");
}

/** Escape literal exclamation marks in a path used in archive display paths. */
string escapeArchiveVirtualPath(string path)
{
    import std.string : replace;

    return path.replace("!", "!!");
}

/** Append one archive-entry path to an already display-encoded container path.
 *
 * Set `occurrence` for same-name entries in the same container. Occurrences
 * are zero based and omitted when the path is unambiguous.
 */
string appendArchiveVirtualPath(string containerPath, string entryPath,
    size_t occurrence = size_t.max)
{
    import std.conv : to;

    auto result = containerPath ~ "!/" ~ escapeArchiveVirtualPath(entryPath);
    if (occurrence != size_t.max)
        result ~= "!~" ~ occurrence.to!string;
    return result;
}

/** One archive layer decoded from a canonical virtual path. */
struct ArchiveVirtualPathLayer
{
    string relativePath; /// Normalized path in this archive layer.
    size_t occurrence; /// Zero-based duplicate-name occurrence.
    bool hasOccurrence; /// False when the member path is unique in its container.
}

/** Physical container path followed by zero or more archive-member layers. */
struct ParsedArchiveVirtualPath
{
    string physicalPath;
    ArchiveVirtualPathLayer[] entries;

    @property bool isVirtual() const
    {
        return entries.length > 0;
    }
}

/** Decode a physical or archive virtual path using the canonical `!/`, `!!`,
 * and `!~N` grammar.
 *
 * Throws: Exception when a literal marker is not escaped or an occurrence
 * suffix is malformed.
 */
ParsedArchiveVirtualPath parseArchiveVirtualPath(string path)
{
    import std.conv : to;

    ParsedArchiveVirtualPath result;
    string current;
    size_t occurrence;
    bool hasOccurrence;
    bool hasContainer;

    void flushEntry()
    {
        if (current.length == 0)
            throw new Exception("Archive virtual paths cannot contain empty layers.");
        if (!hasContainer)
        {
            result.physicalPath = current;
            hasContainer = true;
        }
        else
        {
            bool safe;
            bool isDirectory;
            const auto normalized = normalizeArchiveEntryPath(current, safe,
                isDirectory);
            if (!safe || isDirectory || normalized != current)
                throw new Exception("Archive member path is unsafe or not normalized.");
            result.entries ~= ArchiveVirtualPathLayer(current, occurrence,
                hasOccurrence);
        }
        current = "";
        occurrence = 0;
        hasOccurrence = false;
    }

    for (size_t index; index < path.length; ++index)
    {
        if (path[index] != '!')
        {
            current ~= path[index];
            continue;
        }
        if (index + 1 < path.length && path[index + 1] == '!')
        {
            current ~= '!';
            ++index;
            continue;
        }
        if (index + 1 < path.length && path[index + 1] == '/')
        {
            flushEntry();
            ++index;
            continue;
        }
        if (index + 1 < path.length && path[index + 1] == '~')
        {
            if (!hasContainer || hasOccurrence)
                throw new Exception("Occurrence suffix is not valid in this path layer.");
            auto digitsStart = index + 2;
            auto digitsEnd = digitsStart;
            while (digitsEnd < path.length && path[digitsEnd] >= '0'
                && path[digitsEnd] <= '9')
                ++digitsEnd;
            if (digitsEnd == digitsStart
                || (digitsEnd < path.length
                    && !(digitsEnd + 1 < path.length
                        && path[digitsEnd] == '!' && path[digitsEnd + 1] == '/')))
                throw new Exception("Malformed archive occurrence suffix.");
            try
                occurrence = to!size_t(path[digitsStart .. digitsEnd]);
            catch (Exception)
                throw new Exception("Archive occurrence is outside the supported range.");
            hasOccurrence = true;
            index = digitsEnd - 1;
            continue;
        }
        throw new Exception("Literal exclamation marks must be escaped as '!!'.");
    }

    if (current.length == 0)
        throw new Exception("Archive virtual paths cannot end with an empty layer.");
    if (!hasContainer)
        result.physicalPath = current;
    else
    {
        bool safe;
        bool isDirectory;
        const auto normalized = normalizeArchiveEntryPath(current, safe,
            isDirectory);
        if (!safe || isDirectory || normalized != current)
            throw new Exception("Archive member path is unsafe or not normalized.");
        result.entries ~= ArchiveVirtualPathLayer(current, occurrence,
            hasOccurrence);
    }
    return result;
}

/** Split an archive display path into its physical/member path layers.
 *
 * A literal `!` is encoded as `!!`; `!/` separates a container from its
 * member path. The returned layers have literal exclamation marks restored.
 */
string[] splitArchiveVirtualPath(string path)
{
    auto parsed = parseArchiveVirtualPath(path);
    string[] layers;
    layers ~= parsed.physicalPath;
    foreach (entry; parsed.entries)
        layers ~= entry.relativePath;
    return layers;
}

/** Top-level representation of an archive file.
 *
 * The idea is to have a baseclass with the common interface and then have implementations
 * for the different archive types. The baseclass can be used in the rest of the code and
 * the factory method creates an instance of the correct type. When we need to support a new
 * archive type, we just add a new implementation and extend the factory method.
 */
abstract class FileArchive
{
    /** Archive type represented by the concrete implementation. */
    const ArchiveType fileType;
    /** Path to the archive file on disk. */
    string fileName;

    /** Create a new archive wrapper.
     *
     * Concrete implementations typically call this from their constructor to
     * initialize the shared fields.
     *
     * Params:
     *   type = archive type handled by the concrete implementation.
     *   filename = path to the archive file on disk.
     */
    this(ArchiveType type, string filename)
    {
        fileType = type;
        fileName = filename;
    }

    /** Get list of entries in archive
     *
     * The base implementation returns `null` and is meant to be overridden by
     * concrete archive handlers.
     *
     * Returns:
     *   `null` or the list of entries in the archive.
     */
    string[] getEntries(string password = "")
    {
        return null;
    }

    /** Return stable-shape descriptors without extracting archive members.
     *
     * Identity is expressed as normalized member path plus occurrence in the
     * ordered index. The caller must bind that identity to the container content
     * and `archiveEntryIdentityVersion`; it is not a global ID by itself.
     */
    ArchiveEntryDescriptor[] getEntryDescriptors(string password = "")
    {
        auto names = getEntries(password);
        if (names is null)
            return null;
        size_t[string] occurrences;
        ArchiveEntryDescriptor[] result;
        foreach (index, name; names)
        {
            ArchiveEntryDescriptor descriptor;
            descriptor.index = index;
            descriptor.name = name;
            descriptor.relativePath = normalizeArchiveEntryPath(name,
                descriptor.hasSafePath, descriptor.isDirectory);
            auto occurrenceKey = descriptor.hasSafePath
                ? descriptor.relativePath : name;
            descriptor.occurrence = occurrences.get(occurrenceKey, 0);
            occurrences[occurrenceKey] = descriptor.occurrence + 1;
            result ~= descriptor;
        }
        return result;
    }

    /** Extract entry from archive to destination directory. The destination file is the same as the entry name.
     *
     * The base implementation returns `false` and is meant to be overridden by
     * concrete archive handlers.
     *
     * Params:
     *   filename = name of entry in archive
     *   destDir = directory to extract to
     * Returns:
     *   true on success, false on failure
     */
    bool extractEntry(string filename, string destDir, string password = "")
    {
        return false;
    }

    version (unittest)
    {
        static void createTestArchive()
        {
        }

        static void deleteTestArchive()
        {
        }
    }
}

@("file archive defaults")
unittest
{
	class DummyArchive : FileArchive
	{
		this()
		{
			super(ArchiveType.zip, "dummy.zip");
		}
	}

	auto archive = new DummyArchive();

	assert(archive.fileType == ArchiveType.zip);
	assert(archive.fileName == "dummy.zip");
	assert(archive.getEntries is null);
    assert(!archive.extractEntry("entry.txt", "/tmp"));
}

@("archive entry descriptors normalize paths and distinguish occurrences")
unittest
{
    class DescriptorArchive : FileArchive
    {
        this()
        {
            super(ArchiveType.zip, "descriptor.zip");
        }

        override string[] getEntries(string password = "")
        {
            return ["folder/", "folder\\same.txt", "folder/same.txt",
                "../outside.txt", "/absolute.txt", "./root.txt"];
        }
    }

    auto entries = (new DescriptorArchive()).getEntryDescriptors();
    assert(entries.length == 6);
    assert(entries[0].isDirectory && entries[0].relativePath == "folder");
    assert(entries[1].hasSafePath && entries[1].relativePath == "folder/same.txt");
    assert(entries[1].occurrence == 0);
    assert(entries[2].relativePath == "folder/same.txt");
    assert(entries[2].occurrence == 1);
    assert(!entries[3].hasSafePath && entries[3].relativePath.length == 0);
    assert(!entries[4].hasSafePath && entries[4].relativePath.length == 0);
    assert(entries[5].relativePath == "root.txt");
    assert(archiveEntryIdentityVersion == "path-occurrence-v1");
}

@("archive virtual paths distinguish separators from literal exclamation marks")
unittest
{
    const auto physicalPath = escapeArchiveVirtualPath("dir!/sample!.zip");
    assert(physicalPath == "dir!!/sample!!.zip");
    auto displayPath = appendArchiveVirtualPath(physicalPath,
        "sub!/nested!.zip");
    displayPath = appendArchiveVirtualPath(displayPath, "deep/readme!.txt");
    assert(displayPath
        == "dir!!/sample!!.zip!/sub!!/nested!!.zip!/deep/readme!!.txt");
    const auto layers = splitArchiveVirtualPath(displayPath);
    assert(layers == ["dir!/sample!.zip", "sub!/nested!.zip",
        "deep/readme!.txt"]);

    auto duplicatePath = appendArchiveVirtualPath(physicalPath,
        "same!.txt", 1);
    auto parsedDuplicate = parseArchiveVirtualPath(duplicatePath);
    assert(parsedDuplicate.physicalPath == "dir!/sample!.zip");
    assert(parsedDuplicate.entries.length == 1);
    assert(parsedDuplicate.entries[0].relativePath == "same!.txt");
    assert(parsedDuplicate.entries[0].hasOccurrence);
    assert(parsedDuplicate.entries[0].occurrence == 1);
    assert(splitArchiveVirtualPath(duplicatePath)
        == ["dir!/sample!.zip", "same!.txt"]);

    auto duplicateContainerPath = appendArchiveVirtualPath(physicalPath,
        "nested!.zip", 2);
    duplicateContainerPath = appendArchiveVirtualPath(duplicateContainerPath,
        "deep/readme.txt");
    const auto parsedNested = parseArchiveVirtualPath(duplicateContainerPath);
    assert(parsedNested.entries.length == 2);
    assert(parsedNested.entries[0].relativePath == "nested!.zip");
    assert(parsedNested.entries[0].occurrence == 2);
    assert(parsedNested.entries[1].relativePath == "deep/readme.txt");
    assert(!parsedNested.entries[1].hasOccurrence);

    import std.exception : assertThrown;
    assertThrown!Exception(parseArchiveVirtualPath("archive.zip!/bad!~x.txt"));
    assertThrown!Exception(parseArchiveVirtualPath("archive!.zip!/member.txt"));
    assertThrown!Exception(parseArchiveVirtualPath("archive.zip!/../escape.txt"));
}
