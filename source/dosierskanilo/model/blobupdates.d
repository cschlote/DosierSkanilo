/** Per-blob update jobs: digests, file type, MediaInfo, and torrent metadata.
 *
 * Each job fills one metadata group of a `NamedBinaryBlob` and is run either
 * directly or as a task of the scanner pipeline.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo.model.blobupdates;

import std.algorithm;
import std.array;
import std.datetime.systime : SysTime;
import jsonizer;
import dosierarkivo;
import dosierskanilo.logging;
import dosierskanilo.options;
import dosierskanilo.progress;
import dosierskanilo.metadata.digests;
import dosierskanilo.metadata.mediainfosig;
import dosierskanilo.metadata.torrentinfo;
import dosierskanilo.model.archivespec;
import dosierskanilo.model.checksums;
import dosierskanilo.model.filespec;
import dosierskanilo.model.namedbinaryblob;

/** Calc the Digests, if missing
 *
 * Params:
 *   obj = NamedBinaryBlob object to update
 *   gotCtrlC = shared bool pointer to check for Ctrl-C interrupt
 *   progressCallBack = callback function to report progress
 */
void updateDigests(NamedBinaryBlob obj,
	shared(bool)* gotCtrlC = null,
	ProgressCallBack* progressCallBack = null)
{
	auto hasdigests = obj.checkSums.hasDigests;
	if (!hasdigests)
	{
		/* Virtual archive members cannot be hashed directly; their digests
		 * are provided by the archive scan of the container. */
		auto fileName = obj.getFirstOpenableFileName();
		if (fileName.empty)
			return;

		ubyte[] md, sha, xxh;
		calculatesDigests(gotCtrlC, fileName, &md, &sha, &xxh, progressCallBack);
		obj.checkSums.set_md5sum = md;
		obj.checkSums.set_sha1sum = sha;
		obj.checkSums.set_xxh64 = xxh;
	}
}

@("updateDigest")
unittest
{
	import std.stdio : File;
	import std.path : buildPath;
	import dosierskanilo.testdata : ensureSyntheticTestCatalog;

	auto fixture = ensureSyntheticTestCatalog();
	string filename = buildPath(fixture.catalogRoot, "media", "tone.wav");
	auto fh = File(filename);
	auto dco = new NamedBinaryBlob(filename, fh.size, SysTime(4_237_892));
	updateDigests(dco, null);
	assert(dco.checkSums.hasDigests);
}

/** Query file type text for a blob, if missing.
 *
 * This code is called for a unique binary blob, so using the first existing
 * file entry is sufficient.
 *
 * Params:
 *   obj = NamedBinaryBlob object to update
 *   rescan = force rescan even if file type already exists
 */
void updateFileType(NamedBinaryBlob obj, bool rescan = false)
{
	if (obj.fileType.empty || rescan)
	{
		if (obj.fileSize) // Empty files surely have no info at all....
		{
			auto fileName = obj.getFirstOpenableFileName();
			if (!fileName.empty)
			{
				import dosierskanilo.metadata.fileutilsig : getFileType;

				obj.fileType = getFileType(fileName);
			}
		}
	}
}

@("updateFileType")
unittest
{
	import std.stdio : File;
	import std.path : buildPath;
	import dosierskanilo.testdata : ensureSyntheticTestCatalog;

	auto fixture = ensureSyntheticTestCatalog();
	string filename = buildPath(fixture.catalogRoot, "media", "tone.wav");
	auto fh = File(filename);
	auto dco = new NamedBinaryBlob(filename, fh.size, SysTime(4_237_892));
	updateFileType(dco, true);
	assert(dco.fileType, "No fileType was set.");
}

/** Get mediaInfo tags for file, if missing
 *
 * This code is called for a unique binary blob. So the MediaInfo MUST be
 * identical.
 *
 * Params:
 *   obj = NamedBinaryBlob object to update
 *   rescan = force rescan even if MediaInfo already exists
 */
void updateMediaInfo(NamedBinaryBlob obj, bool rescan = false)
{
	if (obj.mediaInfoSig is null || rescan)
	{
		if (obj.fileSize) // Empty files surely have no info at all....
		{
			auto fileName = obj.getFirstOpenableFileName();
			if (!fileName.empty)
				obj.mediaInfoSig = getMediaTypeSignature(fileName);
		}
	}
}

@("updateMediaInfo")
unittest
{
	import std.stdio : File;
	import std.path : buildPath;
	import dosierskanilo.testdata : ensureSyntheticTestCatalog;

	auto fixture = ensureSyntheticTestCatalog();
	string filename = buildPath(fixture.catalogRoot, "images", "sample.bmp");
	auto fh = File(filename);
	auto dco = new NamedBinaryBlob(filename, fh.size, SysTime(4_237_892));
	updateMediaInfo(dco, true);
	assert(dco.mediaInfoSig, "No MediaInfo was set.");
}


/** Get torrent info for file, if missing
 *
 * Params:
 *   obj = NamedBinaryBlob object to update
 *   rescan = force rescan even if info exists
 */
void updateTorrentInfo(NamedBinaryBlob obj, bool rescan = false)
{
	// Get all existing .torrent files for a bin
	auto torrentFiles =
		obj.getExistingFiles.filter!(a => a.fileName.endsWith(".torrent")).array;
	if (torrentFiles.length == 0)
		return;

	if (obj.torrentInfo is null || rescan)
	{
		if (obj.fileSize) // Empty files surely have no info at all....
		{
			foreach (spec; torrentFiles)
			{
				try
				{
					obj.torrentInfo = getTorrentInfo(spec.fileName);
					break;
				}
				catch (Exception e)
				{
					logFLineVerbose("Cannot analyse torrent: %s", e.msg);
				}
			}
		}
	}
}

@("updateTorrentInfo")
unittest
{
	import std.stdio : File;
	import std.path : buildPath;
	import dosierskanilo.testdata : ensureSyntheticTestCatalog;

	auto fixture = ensureSyntheticTestCatalog();
	string filename = buildPath(fixture.catalogRoot, "torrent", "single-file.torrent");
	auto fh = File(filename);
	auto dco = new NamedBinaryBlob(filename, fh.size, SysTime(4_237_892));
	updateTorrentInfo(dco, true);
	assert(dco.torrentInfo, "No TorrentInfo was set.");
	assert(dco.torrentInfo.isMultiFile == false);

	string filename2 = buildPath(fixture.catalogRoot, "torrent", "multi-file.torrent");
	auto fh2 = File(filename2);
	auto dco2 = new NamedBinaryBlob(filename2, fh2.size, SysTime(4_237_892));
	updateTorrentInfo(dco2, true);
	assert(dco2.torrentInfo, "No TorrentInfo was set.");
	assert(dco2.torrentInfo.isMultiFile == true);

}
