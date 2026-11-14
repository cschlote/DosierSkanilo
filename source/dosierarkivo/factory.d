/** Factory helpers for archive implementations.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierarkivo.factory;

import std.algorithm.searching : endsWith;
import std.file : exists;
import std.string : toLower;

import dosierarkivo.archive;
import dosierarkivo.sevenziparchive;
import dosierarkivo.tararchive;
import dosierarkivo.rararchive;
import dosierarkivo.ziparchive;

/** One supported archive family and its recognized filename suffixes. */
private struct ArchiveFormat
{
    /// Lower-case suffixes accepted for this family.
    string[] suffixes;
    /// Adapter family selected for a matching suffix.
    ArchiveType type;
}

/** Supported archive families ordered by suffix specificity. */
private immutable ArchiveFormat[] archiveFormats = [
    ArchiveFormat([".zip"], ArchiveType.zip),
    ArchiveFormat([
        ".tar",
        ".tar.gz", ".tgz",
        ".tar.bz2", ".tbz2", ".tbz",
        ".tar.xz", ".txz",
        ".tar.zst", ".tzst",
        ".tar.lz", ".tlz", ".tar.lzma",
        ".tar.z", ".taz"
    ], ArchiveType.tar),
    ArchiveFormat([".rar"], ArchiveType.rar),
    ArchiveFormat([".7z"], ArchiveType._7z),
];

/** Select the archive adapter family for a filename.
 *
 * Comparison is case-insensitive and uses the longest matching suffix, so
 * `.tar.gz` wins over a potential shorter suffix. Compression is handled by
 * the tar tool itself; no separate gzip/xz/zstd adapter is needed.
 *
 * Params:
 *     filename = Archive file path or basename.
 * Returns: The matching archive type, or `unknown` when no suffix matches.
 */
private ArchiveType archiveTypeForName(string filename) @safe
{
    const lowerName = filename.toLower;
    ArchiveType result = ArchiveType.unknown;
    size_t bestLength;
    foreach (format; archiveFormats)
        foreach (suffix; format.suffixes)
            if (lowerName.endsWith(suffix) && suffix.length > bestLength)
            {
                bestLength = suffix.length;
                result = format.type;
            }
    return result;
}

/** Factory that creates a FileArchive object for a supported archive type.
 *
 * Compressed tar variants such as `.tar.gz`, `.tgz`, `.tar.xz`, `.tar.zst`,
 * and their common aliases use the regular TAR adapter. The external `tar`
 * tool performs decompression transparently.
 *
 * Params:
 *   filename = archive file path
 * Returns:
 *   FileArchive instance, or null if the file is missing or unsupported.
 */
FileArchive fileArchive(string filename)
{
    if (filename.exists == false)
        return null;

    FileArchive fa;
    switch (archiveTypeForName(filename))
    {
    case ArchiveType.zip:
        fa = new FileArchiveZip(filename);
        break;
    case ArchiveType.tar:
        fa = new FileArchiveTar(filename);
        break;
    case ArchiveType.rar:
        fa = new FileArchiveRar(filename);
        break;
    case ArchiveType._7z:
        fa = new FileArchive7z(filename);
        break;
    case ArchiveType.unknown:
        fa = null;
        break;
    default:
        fa = null;
        break;
    }
    return fa;
}

@("fileArchive() edgecase")
unittest
{
    auto fa = fileArchive("test/not-found.txt");
    assert(fa is null);
}

@("fileArchive() unsupported extension")
unittest
{
	import std.file : remove, tempDir, write;
	import std.path : buildPath;
	import std.uuid : randomUUID;

	auto tmpFile = buildPath(tempDir(), "archive-factory-" ~ randomUUID().toString() ~ ".txt");
	scope (exit)
	{
		if (exists(tmpFile))
			remove(tmpFile);
	}
	write(tmpFile, "not an archive");
	auto fa = fileArchive(tmpFile);
	assert(fa is null);
}

@("fileArchive() recognizes compressed tar suffixes")
unittest
{
	import std.file : exists, remove, tempDir, write;
	import std.path : buildPath;
	import std.uuid : randomUUID;

	const root = buildPath(tempDir(), "archive-factory-tar-"
		~ randomUUID().toString());
	scope (exit)
		if (exists(root))
			remove(root);

	foreach (suffix; [
		".tar",
		".tar.gz", ".tgz",
		".tar.bz2", ".tbz2", ".tbz",
		".tar.xz", ".txz",
		".tar.zst", ".tzst",
		".tar.lz", ".tlz", ".tar.lzma",
		".tar.z", ".taz"
	])
	{
		const path = root ~ suffix;
		write(path, "");
		scope (exit)
			if (exists(path))
				remove(path);
		auto archive = fileArchive(path);
		assert(archive !is null, suffix);
		assert(archive.fileType == ArchiveType.tar, suffix);
	}

	const plainGzip = root ~ ".gz";
	write(plainGzip, "");
	scope (exit)
		if (exists(plainGzip))
			remove(plainGzip);
	assert(fileArchive(plainGzip) is null,
		"a plain .gz file is not a supported tar archive");
}
