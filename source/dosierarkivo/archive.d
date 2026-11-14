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

/** Character that escapes itself and introduces archive path markers.
 *
 * Changing this value requires a catalog migration that rewrites every stored
 * relative path and regenerates the `is_virtual` column. All grammar and
 * filter helpers derive their markers from this constant.
 */
enum char archivePathEscapeChar = '!';

/** Character that introduces a duplicate-occurrence suffix. */
enum char archivePathOccurrenceChar = '~';

static assert(archivePathEscapeChar != '\'', "SQL helpers quote this character");
static assert(archivePathEscapeChar != '/', "The path separator cannot escape itself");
static assert(archivePathEscapeChar != '\0', "NUL cannot appear in a path");

/** Raised when an archive operation needs a password or rejects the supplied one. */
class ArchivePasswordRequiredException : Exception
{
    /** Construct the exception with a diagnostic message.
     *
     * Params:
     *     message = Human-readable reason, usually the archive tool output.
     */
    this(string message)
    {
        super(message);
    }
}

/** Raised when an interactive password request is cancelled by the caller. */
class ArchivePasswordCancelledException : Exception
{
    /** Construct the exception with a diagnostic message.
     *
     * Params:
     *     message = Human-readable reason for the cancellation.
     */
    this(string message)
    {
        super(message);
    }
}

/** Raised when an external archive tool exits unsuccessfully. */
class ArchiveToolException : Exception
{
    /** Construct the exception with a diagnostic message.
     *
     * Params:
     *     message = Human-readable reason, usually the archive tool output.
     */
    this(string message)
    {
        super(message);
    }
}

/** Callback that requests a password; return false when the request is cancelled. */
alias ArchivePasswordCallback = bool delegate(string archivePath, string reason,
    out string password);

/** Whether external archive-tool output indicates a missing or rejected password.
 *
 * Params:
 *     output = Combined tool output to inspect; matching is case-insensitive.
 * Returns: `true` when the text mentions a password, encryption or passphrase.
 */
bool isArchivePasswordFailure(string output)
{
    auto message = output.toLower;
    return message.canFind("password") || message.canFind("encrypted")
        || message.canFind("passphrase");
}

/** Types of archives we support. */
enum ArchiveType
{
    /// No supported archive format was recognized.
    unknown,
    /// ZIP archive handled by `FileArchiveZip`.
    zip,
    /// TAR archive handled by `FileArchiveTar`.
    tar,
    /// RAR archive handled by `FileArchiveRar`.
    rar,
    /// 7z archive handled by `FileArchive7z`.
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
    bool hasDuplicateName; /// True when another entry has the same normalized path.
}

/** Convert native path separators to the slash form used in catalog storage.
 *
 * On POSIX a backslash is a legal filename character and must be preserved.
 *
 * Params:
 *     path = Path in native spelling.
 * Returns: The path with backslashes replaced by slashes on Windows, otherwise
 *     the input unchanged.
 */
string nativePathToStoragePath(string path) @safe
{
    import std.string : replace;

    version (Windows)
        return path.replace('\\', '/');
    else
        return path;
}

/** Normalize a member name without permitting absolute or traversal paths.
 *
 * Params:
 *     name = Raw member name from the archive index.
 *     safe = Set to `false` for absolute, drive-qualified or traversal paths and
 *         for names containing NUL.
 *     isDirectory = Set to `true` when the raw name ends with a slash.
 * Returns: The slash-separated normalized path, or an empty string when the
 *     name is unsafe.
 */
string normalizeArchiveEntryPath(string name, out bool safe, out bool isDirectory) @safe
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

/** Canonical doubled form of the archive path escape character.
 *
 * Returns: The escape character repeated twice.
 */
string archivePathEscapeSequence() @safe
{
    import std.conv : to;

    const marker = archivePathEscapeChar.to!string;
    return marker ~ marker;
}

/** Escape literal marker characters in a path used in archive display paths.
 *
 * Params:
 *     path = Unescaped path text.
 * Returns: The path with every escape character doubled.
 */
string escapeArchiveVirtualPath(string path) @safe
{
    import std.conv : to;
    import std.string : replace;

    const marker = archivePathEscapeChar.to!string;
    return path.replace(marker, archivePathEscapeSequence());
}

/** Canonical separator between a container path and its member path.
 *
 * Returns: The escape character followed by `/`.
 */
string archivePathSeparator() @safe
{
    import std.conv : to;

    return archivePathEscapeChar.to!string ~ "/";
}

/** Canonical marker before a duplicate-occurrence number.
 *
 * Returns: The escape character followed by the occurrence marker character.
 */
string archivePathOccurrenceMarker() @safe
{
    import std.conv : to;

    return archivePathEscapeChar.to!string ~ archivePathOccurrenceChar.to!string;
}

/** Append one archive-entry path to an already display-encoded container path.
 *
 * Set `occurrence` for same-name entries in the same container. Occurrences
 * are zero based and omitted when the path is unambiguous.
 *
 * Params:
 *     containerPath = Display-encoded outer path.
 *     entryPath = Member path to append; literal markers are escaped here.
 *     occurrence = Zero-based duplicate occurrence, or `size_t.max` to omit the
 *         occurrence suffix.
 * Returns: The combined canonical virtual path.
 */
string appendArchiveVirtualPath(string containerPath, string entryPath,
    size_t occurrence = size_t.max) @safe
{
    import std.conv : to;

    auto result = containerPath ~ archivePathSeparator()
        ~ escapeArchiveVirtualPath(entryPath);
    if (occurrence != size_t.max)
        result ~= archivePathOccurrenceMarker() ~ occurrence.to!string;
    return result;
}

/** Decode doubled escape markers for display and text matching.
 *
 * Params:
 *     path = Canonical path with doubled escapes.
 * Returns: The path with every doubled escape marker reduced to one character.
 */
string archiveDisplayPath(string path) @safe
{
    import std.conv : to;
    import std.string : replace;

    return path.replace(archivePathEscapeSequence(),
        archivePathEscapeChar.to!string);
}

/** SQL expression that decodes a canonical path for text matching.
 *
 * Params:
 *     expression = SQL expression producing the canonical path value.
 * Returns: A SQL `replace(...)` expression yielding the decoded display form.
 */
string archivePathDisplaySql(string expression)
{
    import std.conv : to;
    import std.format : format;

    return format("replace(%s, '%s', '%s')", expression,
        archivePathEscapeSequence(), archivePathEscapeChar.to!string);
}

/** SQL expression for the generated `is_virtual` file-reference column.
 *
 * Literal escape characters are removed in their doubled form; a remaining
 * single escape character followed by `/` marks an archive layer.
 *
 * Params:
 *     column = Name or expression of the canonical path column.
 * Returns: A SQL boolean expression that is true for virtual archive paths.
 */
string archiveVirtualColumnSql(string column = "relative_path")
{
    import std.conv : to;
    import std.format : format;

    const marker = archivePathEscapeChar.to!string;
    return format("instr(replace(%s, '%s', ''), '%s') > 0", column,
        marker ~ marker, marker ~ "/");
}

/** SQL predicate matching display or canonical text against a canonical path.
 *
 * Both the stored spelling and its decoded display form are searched so a
 * filter works for user-visible names containing the escape character as well
 * as for archive separator searches.
 *
 * Params:
 *     column = Name or expression of the canonical path column.
 *     parameter = SQL expression that yields the search text.
 *     caseSensitive = When false, both sides are compared after `lower(...)`.
 * Returns: A SQL predicate true when either spelling contains the text.
 */
string archivePathFilterSql(string column, string parameter,
    bool caseSensitive)
{
    import std.format : format;

    const pathExpression = caseSensitive ? column : "lower(" ~ column ~ ")";
    const displayExpression = caseSensitive
        ? archivePathDisplaySql(column)
        : "lower(" ~ archivePathDisplaySql(column) ~ ")";
    const textExpression = caseSensitive ? parameter
        : "lower(" ~ parameter ~ ")";
    return format("(instr(%s, %s) > 0 OR instr(%s, %s) > 0)",
        pathExpression, textExpression, displayExpression, textExpression);
}

/** Match display or canonical text against a canonical path in memory.
 *
 * Params:
 *     path = Canonical path in stored spelling.
 *     text = Search text.
 *     caseSensitive = When false, comparison ignores letter case.
 * Returns: `true` when either the canonical or decoded path contains `text`.
 */
bool archivePathMatchesText(string path, string text,
    bool caseSensitive = false)
{
    import std.string : toLower;

    const candidate = caseSensitive ? path : path.toLower;
    const display = caseSensitive
        ? archiveDisplayPath(path) : archiveDisplayPath(path).toLower;
    const needle = caseSensitive ? text : text.toLower;
    return candidate.canFind(needle) || display.canFind(needle);
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
    string physicalPath; /// Physical container path after decoding escapes.
    ArchiveVirtualPathLayer[] entries; /// Decoded archive layers, outermost first.

    /** Whether at least one archive-member layer follows the physical path.
     *
     * Returns: `true` when `entries` is non-empty, i.e. the path addresses a
     *     member inside an archive rather than a plain file.
     */
    @property bool isVirtual() const @safe
    {
        return entries.length > 0;
    }
}

/** Decode a physical or archive virtual path using the canonical grammar.
 *
 * The escape character doubles itself, `<escape>/` separates a container from
 * its member path, and `<escape>~N` disambiguates duplicate member names.
 *
 * Params:
 *     path = Canonical path to decode.
 * Returns: The physical path and its decoded archive layers, outermost first.
 * Throws: Exception when a literal marker is not escaped or an occurrence
 * suffix is malformed.
 */
ParsedArchiveVirtualPath parseArchiveVirtualPath(string path) @safe
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
        if (path[index] != archivePathEscapeChar)
        {
            current ~= path[index];
            continue;
        }
        if (index + 1 < path.length
            && path[index + 1] == archivePathEscapeChar)
        {
            current ~= archivePathEscapeChar;
            ++index;
            continue;
        }
        if (index + 1 < path.length && path[index + 1] == '/')
        {
            flushEntry();
            ++index;
            continue;
        }
        if (index + 1 < path.length
            && path[index + 1] == archivePathOccurrenceChar)
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
                        && path[digitsEnd] == archivePathEscapeChar
                        && path[digitsEnd + 1] == '/')))
                throw new Exception("Malformed archive occurrence suffix.");
            try
                occurrence = to!size_t(path[digitsStart .. digitsEnd]);
            catch (Exception)
                throw new Exception("Archive occurrence is outside the supported range.");
            hasOccurrence = true;
            index = digitsEnd - 1;
            continue;
        }
        throw new Exception("Literal archive path markers must be escaped.");
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
 * A literal escape character is doubled; `<escape>/` separates a container
 * from its member path. The returned layers have literal markers restored.
 *
 * Params:
 *     path = Canonical path to split.
 * Returns: The physical path followed by each member layer, outermost first.
 * Throws: Exception when the path does not follow the canonical grammar.
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

/** Return the human-facing final name of a canonical path.
 *
 * Physical paths and archive member paths decode literal `!!` escapes. A path
 * that does not follow the canonical grammar falls back to its raw final
 * component so legacy literal names remain visible unchanged.
 *
 * Params:
 *     path = Canonical or legacy path.
 * Returns: The decoded final path component, or an empty string for a path
 *     that splits into no layers.
 */
string archiveDisplayBaseName(string path)
{
    import std.path : baseName;

    try
    {
        const layers = splitArchiveVirtualPath(path);
        return layers.length > 0 ? baseName(layers[$ - 1]) : "";
    }
    catch (Exception)
        return baseName(path);
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
     * Params:
     *   password = optional archive password.
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
     *
     * Params:
     *     password = Optional archive password.
     * Returns: One descriptor per entry in listing order, or `null` when the
     *     underlying `getEntries` returns `null`.
     */
    ArchiveEntryDescriptor[] getEntryDescriptors(string password = "")
    {
        auto names = getEntries(password);
        if (names is null)
            return null;
        ArchiveEntryDescriptor[] result;
        foreach (name; names)
        {
            ArchiveEntryDescriptor descriptor;
            descriptor.name = name;
            result ~= descriptor;
        }
        return finalizeDescriptors(result);
    }

    /** Normalize names, assign indexes, and compute duplicate occurrences.
     *
     * Adapters that parse size and timestamp metadata call this once after
     * pairing their listing rows with `getEntries()` names. Metadata flags and
     * values survive the normalization.
     *
     * Params:
     *     input = Descriptors with at least `name` populated, in listing order.
     * Returns: The normalized descriptors with occurrence and duplicate flags.
     */
    protected ArchiveEntryDescriptor[] finalizeDescriptors(
        ArchiveEntryDescriptor[] input)
    {
        size_t[string] occurrences;
        foreach (index, ref descriptor; input)
        {
            descriptor.index = index;
            bool nameIsDirectory;
            descriptor.relativePath = normalizeArchiveEntryPath(descriptor.name,
                descriptor.hasSafePath, nameIsDirectory);
            descriptor.isDirectory = descriptor.isDirectory || nameIsDirectory;
            const auto occurrenceKey = descriptor.hasSafePath
                ? descriptor.relativePath : descriptor.name;
            descriptor.occurrence = occurrences.get(occurrenceKey, 0);
            occurrences[occurrenceKey] = descriptor.occurrence + 1;
        }
        size_t[string] pathCounts;
        foreach (descriptor; input)
        {
            const auto identityPath = descriptor.hasSafePath
                ? descriptor.relativePath : descriptor.name;
            pathCounts[identityPath] = pathCounts.get(identityPath, 0) + 1;
        }
        foreach (ref descriptor; input)
        {
            const auto identityPath = descriptor.hasSafePath
                ? descriptor.relativePath : descriptor.name;
            descriptor.hasDuplicateName = pathCounts.get(identityPath, 0) > 1;
        }
        return input;
    }

    /** Extract entry from archive to destination directory. The destination file is the same as the entry name.
     *
     * The base implementation returns `false` and is meant to be overridden by
     * concrete archive handlers.
     *
     * Params:
     *   filename = name of entry in archive
     *   destDir = directory to extract to
     *   password = optional archive password
     * Returns:
     *   true on success, false on failure
     */
    bool extractEntry(string filename, string destDir, string password = "")
    {
        return false;
    }

    /** Extract one descriptor occurrence when the format adapter can select it.
     *
     * Params:
     *     descriptor = Entry identity from `getEntryDescriptors`.
     *     destDir = Directory that receives the extracted member.
     *     password = Optional archive password.
     * Returns: `true` on success; `false` when the entry has a duplicate name
     *     or the underlying extraction fails.
     */
    bool extractEntry(ArchiveEntryDescriptor descriptor, string destDir,
        string password = "")
    {
        if (descriptor.hasDuplicateName)
            return false;
        return extractEntry(descriptor.name, destDir, password);
    }

    /** Extract every member of the archive into one destination directory.
     *
     * Bulk extraction is a deep-scan fast path. The caller is responsible for
     * providing an empty, bounded staging directory and for validating the
     * extracted paths before reading them. The base implementation returns
     * `false` and is meant to be overridden by concrete archive handlers.
     *
     * Params:
     *     destDir = directory that receives the complete archive tree
     *     password = optional archive password
     * Returns:
     *     true on success, false when the adapter does not support bulk
     *     extraction
     * Throws:
     *     `ArchivePasswordRequiredException` when a password is missing or
     *     rejected, `ArchiveToolException` for other tool failures.
     */
    bool extractAllTo(string destDir, string password = "")
    {
        return false;
    }

    /** Whether this adapter can select a particular duplicate-name occurrence.
     *
     * Returns: `true` when occurrence-aware extraction is implemented; the
     *     base implementation returns `false`.
     */
    @property bool supportsEntryOccurrence() const
    {
        return false;
    }

    version (unittest)
    {
        /** No-op test-archive hook; subclasses override it to build fixtures. */
        static void createTestArchive()
        {
        }

        /** No-op test-archive hook; subclasses override it to remove fixtures. */
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

@("archive display names decode canonical escape sequences")
unittest
{
    assert(archiveDisplayBaseName("dir!!/clip!!.mp4") == "clip!.mp4");
    assert(archiveDisplayBaseName(
        "container!!.zip!/nested/readme!!.txt") == "readme!.txt");
    /* Legacy literal names do not parse and stay unchanged. */
    assert(archiveDisplayBaseName("literal!.mp4") == "literal!.mp4");
}

@("archive path filters accept display and canonical spelling")
unittest
{
    assert(archivePathMatchesText("dir!!/clip!!.mp4", "dir!/clip!.mp4"));
    assert(archivePathMatchesText("dir!!/clip!!.mp4", "dir!!/clip!!.mp4"));
    assert(archivePathMatchesText("Archive!!/CLIP.mp4", "archive!/clip.mp4"));
    assert(archivePathMatchesText("container.zip!/member!!.txt",
        "container.zip!/member!.txt"));
    assert(!archivePathMatchesText("dir!!/clip!!.mp4", "clip!.exe"));
}
