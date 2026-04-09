/** Factory helpers for archive implementations.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, Released under CC-BY-NC-SA 4.0 license, 2018
 * License: CC-BY-NC-SA 4.0
 */
module dosierarkivo.factory;

import std.file : exists;
import std.path : extension;
import std.string : toLower;

import dosierarkivo.archive;
import dosierarkivo.sevenziparchive;
import dosierarkivo.tararchive;
import dosierarkivo.rararchive;
import dosierarkivo.ziparchive;

/** Factory that creates a FileArchive object for a supported archive type.
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
    switch (filename.toLower.extension)
    {
    case ZIP_SUFFIX:
        fa = new FileArchiveZip(filename);
        break;
    case TAR_SUFFIX:
        fa = new FileArchiveTar(filename);
        break;
    case RAR_SUFFIX:
        fa = new FileArchiveRar(filename);
        break;
    case _7Z_SUFFIX:
        fa = new FileArchive7z(filename);
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
