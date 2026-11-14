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
