/** Archive bulk-extraction policy shared by scanner and frontends.
 *
 * This module deliberately has no operation-lease or cache dependencies so
 * value types such as `MetadataScanOptions` can use the policy enum without
 * creating a module-constructor cycle.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo.archivebulkpolicy;

import std.algorithm.searching : canFind;
import std.conv : to;
import std.file : exists, getSize, isFile, isSymlink;
import std.path : buildPath;
import std.string : empty, split, toLower;

import dosierarkivo.archive : ArchiveEntryDescriptor, ArchiveType;

/** Policy controlling bulk extraction during a deep archive scan. */
enum ArchiveBulkMode
{
    /// Bulk-extract when the archive and available space make it worthwhile.
    automatic,
    /// Bulk-extract every eligible archive regardless of member count.
    always,
    /// Never bulk-extract; keep the per-member cache path.
    never
}

/** Minimum entry count for automatic bulk extraction. */
enum size_t minimumAutomaticBulkEntries = 2;

/** Extra staging bytes reserved beyond the declared member sizes. */
enum ulong archiveBulkSlackBytes = 16UL * 1024UL * 1024UL;

/** Maximum number of member names passed to one chunk extraction. */
enum size_t maximumArchiveChunkMembers = 512;

/** Smallest adaptive chunk target. */
enum ulong minimumArchiveChunkBytes = 256UL * 1024UL * 1024UL;

/** Largest adaptive chunk target. */
enum ulong maximumArchiveChunkBytes = 4UL * 1024UL * 1024UL * 1024UL;

/** Fallback staging limit when the filesystem cannot be queried. */
enum ulong fallbackArchiveStagingByteLimit = 1UL * 1024UL * 1024UL * 1024UL;

/** Upper bound for the automatically derived staging limit. */
enum ulong maximumArchiveStagingByteLimit = 16UL * 1024UL * 1024UL * 1024UL;

/** Parse a CLI bulk-extraction mode.
 *
 * Params:
 *     text = `auto`, `always`, or `never`; matching is case-insensitive.
 *     mode = Receives the parsed mode.
 * Returns: `true` when the value is recognized, otherwise `false`.
 */
bool parseArchiveBulkMode(string text, out ArchiveBulkMode mode) @safe
{
    switch (text.toLower)
    {
    case "auto":
    case "automatic":
        mode = ArchiveBulkMode.automatic;
        return true;
    case "always":
        mode = ArchiveBulkMode.always;
        return true;
    case "never":
        mode = ArchiveBulkMode.never;
        return true;
    default:
        return false;
    }
}

/** Return the CLI spelling of a bulk-extraction mode.
 *
 * Params:
 *     mode = Mode to render.
 * Returns: `auto`, `always`, or `never`.
 */
string archiveBulkModeName(ArchiveBulkMode mode) @safe
{
    final switch (mode)
    {
    case ArchiveBulkMode.automatic:
        return "auto";
    case ArchiveBulkMode.always:
        return "always";
    case ArchiveBulkMode.never:
        return "never";
    }
}

/** Parse a configured bulk-extraction mode.
 *
 * Params:
 *     text = `auto`, `always`, or `never`.
 * Returns: The parsed mode.
 * Throws: `Exception` when the value is not recognized.
 */
ArchiveBulkMode archiveBulkModeFromOption(string text)
{
    ArchiveBulkMode mode;
    if (!parseArchiveBulkMode(text, mode))
        throw new Exception("Unknown archive bulk mode: " ~ text);
    return mode;
}

/** One bulk-extraction decision for an archive. */
struct ArchiveBulkPlan
{
    /// Whether the archive should be extracted as a whole.
    bool useBulk;
    /// Estimated staging bytes, including slack, when `useBulk` is true.
    ulong requiredBytes;
    /// Human-readable reason for logging and tests.
    string reason;
}

/** Decide whether a deep scan should bulk-extract one archive.
 *
 * Names, sizes, and safe paths come from the shallow descriptor listing. The
 * function deliberately rejects archives with unknown member sizes or unsafe
 * member paths: such archives keep the isolated per-member path.
 *
 * Params:
 *     entries = Archive descriptors in listing order.
 *     mode = Bulk-extraction policy.
 *     type = Archive format, used only for diagnostics today.
 * Returns: The plan; `useBulk` is false when per-member extraction is safer.
 */
ArchiveBulkPlan planArchiveBulkExtraction(ArchiveEntryDescriptor[] entries,
    ArchiveBulkMode mode, ArchiveType type = ArchiveType.unknown) @safe
{
    import std.string : format;

    ArchiveBulkPlan plan;
    if (mode == ArchiveBulkMode.never)
    {
        plan.reason = "bulk extraction disabled";
        return plan;
    }
    if (entries.length == 0)
    {
        plan.reason = "archive has no entries";
        return plan;
    }
    ulong totalBytes;
    size_t fileEntries;
    foreach (descriptor; entries)
    {
        if (!descriptor.hasSafePath)
        {
            plan.reason = "archive contains an unsafe member path";
            return plan;
        }
        if (descriptor.isDirectory)
            continue;
        ++fileEntries;
        if (!descriptor.hasSize)
        {
            plan.reason = "archive does not declare member sizes";
            return plan;
        }
        if (ulong.max - totalBytes < descriptor.size)
        {
            plan.reason = "declared member sizes exceed the staging range";
            return plan;
        }
        totalBytes += descriptor.size;
    }
    if (fileEntries == 0)
    {
        plan.reason = "archive has no file members";
        return plan;
    }
    if (mode == ArchiveBulkMode.automatic
        && fileEntries < minimumAutomaticBulkEntries)
    {
        plan.reason = "too few file members for automatic bulk extraction";
        return plan;
    }
    if (mode == ArchiveBulkMode.automatic && totalBytes == 0)
    {
        plan.reason = "archive members are empty";
        return plan;
    }

    ulong slack = archiveBulkSlackBytes;
    const proportionalSlack = totalBytes / 10;
    if (proportionalSlack > slack)
        slack = proportionalSlack;
    if (ulong.max - totalBytes < slack)
    {
        plan.reason = "declared member sizes exceed the staging range";
        return plan;
    }

    plan.useBulk = true;
    plan.requiredBytes = totalBytes + slack;
    plan.reason = format("bulk extraction for %d member(s), %s format, %d bytes",
        fileEntries, type.to!string, totalBytes);
    return plan;
}

/** One bounded archive-extraction chunk. */
struct ArchiveChunkPlan
{
    /// First descriptor index covered by this chunk.
    size_t startIndex;
    /// One past the last descriptor index covered by this chunk.
    size_t endIndex;
    /// Estimated staging bytes, including slack, for selectable members.
    ulong requiredBytes;
    /// Member names passed to the adapter in one tool invocation.
    string[] names;
    /// Whether at least one member can be extracted by name.
    bool eligible;
}

/** Test whether one descriptor can be selected by name for chunk extraction.
 *
 * Duplicate occurrences, unsafe paths, directories, unknown sizes, and names
 * with tool wildcard or escape metacharacters stay on the per-member fallback.
 *
 * Params:
 *     descriptor = Descriptor from the archive listing.
 * Returns: `true` when the member name is safe to pass to a chunk tool.
 */
private bool chunkSelectable(const ArchiveEntryDescriptor descriptor) @safe
{
    const name = descriptor.name;
    return descriptor.hasSafePath && !descriptor.isDirectory
        && !descriptor.hasDuplicateName && descriptor.hasSize
        && name.length > 0 && !name.canFind("*") && !name.canFind("?")
        && !name.canFind("[") && !name.canFind("\\");
}

/** Build one bounded chunk starting at a descriptor index.
 *
 * Ineligible descriptors inside the chunk range are still covered by the
 * range; they simply fall back to the per-member cache. At least one
 * descriptor is always consumed so callers can make progress.
 *
 * Params:
 *     entries = Complete descriptor listing.
 *     startIndex = First descriptor to cover.
 *     targetBytes = Preferred sum of selectable member sizes.
 *     maximumMembers = Preferred maximum number of names in one invocation.
 * Returns: The chunk plan. `eligible` is false when the first descriptor has
 *     no selectable member; `endIndex` still advances by one.
 */
ArchiveChunkPlan planArchiveChunk(ArchiveEntryDescriptor[] entries,
    size_t startIndex, ulong targetBytes = maximumArchiveChunkBytes,
    size_t maximumMembers = maximumArchiveChunkMembers) @safe
{
    ArchiveChunkPlan plan;
    plan.startIndex = startIndex;
    plan.endIndex = startIndex;
    if (startIndex >= entries.length)
        return plan;

    ulong totalBytes;
    size_t endIndex = startIndex;
    foreach (index; startIndex .. entries.length)
    {
        const descriptor = entries[index];
        if (chunkSelectable(descriptor))
        {
            if (plan.names.length > 0
                && (plan.names.length >= maximumMembers
                    || totalBytes + descriptor.size > targetBytes))
                break;
            plan.names ~= descriptor.name;
            totalBytes += descriptor.size;
        }
        endIndex = index + 1;
        if (plan.names.length >= maximumMembers
            || totalBytes >= targetBytes)
            break;
    }

    plan.endIndex = endIndex;
    if (plan.names.length == 0)
    {
        plan.endIndex = startIndex + 1;
        return plan;
    }

    ulong slack = archiveBulkSlackBytes;
    const proportionalSlack = totalBytes / 10;
    if (proportionalSlack > slack)
        slack = proportionalSlack;
    plan.requiredBytes = totalBytes + slack;
    plan.eligible = true;
    return plan;
}

/** Return a fixed member path inside a bulk-extracted tree.
 *
 * Params:
 *     root = Staging directory that received the complete archive.
 *     descriptor = Member descriptor from the same archive listing.
 * Returns: The extracted regular-file path, or an empty string when the
 *     member is a directory, ambiguous duplicate, symlink, or missing. An
 *     empty result tells the caller to use the per-member cache fallback.
 */
string bulkExtractedMemberPath(string root,
    ArchiveEntryDescriptor descriptor) @safe
{
    if (!descriptor.hasSafePath || descriptor.isDirectory
        || descriptor.hasDuplicateName || descriptor.relativePath.empty)
        return "";

    string current = root;
    foreach (component; descriptor.relativePath.split("/"))
    {
        if (component.empty || component == ".")
            continue;
        current = buildPath(current, component);
        if (isSymlink(current))
            return "";
    }
    if (!exists(current) || !isFile(current))
        return "";
    if (descriptor.hasSize && getSize(current) != descriptor.size)
        return "";
    return current;
}

@("bulk plans follow the selected policy")
unittest
{
    ArchiveEntryDescriptor[] entries;
    foreach (index; 0 .. 4)
    {
        ArchiveEntryDescriptor descriptor;
        descriptor.index = index;
        descriptor.name = "member-" ~ index.to!string ~ ".bin";
        descriptor.relativePath = descriptor.name;
        descriptor.hasSafePath = true;
        descriptor.size = 1024;
        descriptor.hasSize = true;
        entries ~= descriptor;
    }

    assert(!planArchiveBulkExtraction(entries,
        ArchiveBulkMode.never).useBulk);
    assert(planArchiveBulkExtraction(entries,
        ArchiveBulkMode.always).useBulk);
    auto automatic = planArchiveBulkExtraction(entries,
        ArchiveBulkMode.automatic);
    assert(automatic.useBulk);
    assert(automatic.requiredBytes >= 4 * 1024);
}

@("bulk plans reject unknown sizes and unsafe paths")
unittest
{
    ArchiveEntryDescriptor descriptor;
    descriptor.name = "member.bin";
    descriptor.relativePath = "member.bin";
    descriptor.hasSafePath = true;

    auto unknownSize = planArchiveBulkExtraction([descriptor],
        ArchiveBulkMode.always);
    assert(!unknownSize.useBulk);
    assert(unknownSize.reason.length > 0);

    descriptor.size = 4;
    descriptor.hasSize = true;
    descriptor.hasSafePath = false;
    auto unsafe = planArchiveBulkExtraction([descriptor],
        ArchiveBulkMode.always);
    assert(!unsafe.useBulk);
    assert(unsafe.reason.length > 0);
}

@("bulk mode parsing accepts the documented spellings")
unittest
{
    ArchiveBulkMode mode;
    assert(parseArchiveBulkMode("auto", mode));
    assert(mode == ArchiveBulkMode.automatic);
    assert(parseArchiveBulkMode("ALWAYS", mode));
    assert(mode == ArchiveBulkMode.always);
    assert(parseArchiveBulkMode("never", mode));
    assert(mode == ArchiveBulkMode.never);
    assert(!parseArchiveBulkMode("sometimes", mode));
}

@("archive chunks stay within their byte and member limits")
unittest
{
    ArchiveEntryDescriptor[] entries;
    foreach (index; 0 .. 4)
    {
        ArchiveEntryDescriptor descriptor;
        descriptor.index = index;
        descriptor.name = "member-" ~ index.to!string ~ ".bin";
        descriptor.relativePath = descriptor.name;
        descriptor.hasSafePath = true;
        descriptor.size = 1024;
        descriptor.hasSize = true;
        entries ~= descriptor;
    }

    auto first = planArchiveChunk(entries, 0, 2500, 512);
    assert(first.eligible);
    assert(first.names.length == 2, first.names.length.to!string);
    assert(first.endIndex == 2, first.endIndex.to!string);
    auto second = planArchiveChunk(entries, first.endIndex, 2500, 512);
    assert(second.eligible);
    assert(second.names.length == 2);
    assert(second.endIndex == 4);
}

@("archive chunks exclude duplicate and wildcard members")
unittest
{
    ArchiveEntryDescriptor duplicate;
    duplicate.name = "same.txt";
    duplicate.relativePath = "same.txt";
    duplicate.hasSafePath = true;
    duplicate.hasSize = true;
    duplicate.size = 10;
    duplicate.hasDuplicateName = true;

    ArchiveEntryDescriptor wildcard;
    wildcard.name = "photo*.jpg";
    wildcard.relativePath = "photo*.jpg";
    wildcard.hasSafePath = true;
    wildcard.hasSize = true;
    wildcard.size = 10;

    ArchiveEntryDescriptor normal;
    normal.name = "normal.txt";
    normal.relativePath = "normal.txt";
    normal.hasSafePath = true;
    normal.hasSize = true;
    normal.size = 10;

    auto chunk = planArchiveChunk([duplicate, wildcard, normal], 0, 1_000_000,
        512);
    assert(chunk.eligible);
    assert(chunk.names.length == 1 && chunk.names[0] == "normal.txt",
        chunk.names.to!string);
    assert(chunk.endIndex == 3);

    auto noMembers = planArchiveChunk([duplicate], 0, 1_000_000, 512);
    assert(!noMembers.eligible);
    assert(noMembers.endIndex == 1);
}
