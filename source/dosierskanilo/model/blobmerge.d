/** Duplicate merging and cleanup for `NamedBinaryBlob` records.
 *
 * Blobs with equal size and complete checksums are combined; invalidated
 * records are removed after a successful merge.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo.model.blobmerge;

import std.algorithm;
import std.array;
import std.datetime.systime : SysTime;
import std.exception : assertThrown, enforce;
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

/** Merge identical binblobs into a new combined object
 *
 * Params:
 *     objs = list of identical objects to merge; must contain at least two.
 * Returns: A copy of the first object with merged metadata and deduplicated
 *     file references from all inputs.
 * Throws: `Exception` when fewer than two objects are supplied, digests are
 *     missing, or metadata differs between the inputs.
 */
NamedBinaryBlob mergeDataClassObjects(NamedBinaryBlob[] objs)
{
	import std.string : format;

	enforce(objs.length >= 2, "Need at least 2 objects");
	enforce(objs.filter!(a => a.checkSums.hasDigests).array.length > 0,
		"Missing checksums.");

	string mergedFileType;
	MediaInfoSig mergedMediaInfo;
	TorrentInfo mergedTorrentInfo;
	string mergedArchivePassword;
	ArchiveSpec[] mergedArchiveSpecs;
	bool mergedArchiveIndexKnown;
	bool mergedArchiveIndexDeep;
	size_t mergedArchiveScanCursor;

	foreach (obj; objs)
	{
		enforce(objs[0] == obj, "Objects not identical.\n%s\n%s\n"
				.format(objs[0].toString, obj.toString));
		if (obj.fileType.length > 0)
		{
			if (mergedFileType.length == 0)
				mergedFileType = obj.fileType;
			else
				enforce(mergedFileType == obj.fileType,
					"Mismatching fileType");
		}
		if (obj.mediaInfoSig !is null)
		{
			if (mergedMediaInfo is null)
				mergedMediaInfo = obj.mediaInfoSig;
			else
				enforce(mergedMediaInfo == obj.mediaInfoSig,
					"Mismatching MediaInfoSig");
		}
		if (obj.torrentInfo !is null)
		{
			if (mergedTorrentInfo is null)
				mergedTorrentInfo = obj.torrentInfo;
			else
				enforce(toJSONString(mergedTorrentInfo)
					== toJSONString(obj.torrentInfo), "Mismatching TorrentInfo");
		}
		if (obj.archivePassword.length > 0)
		{
			if (mergedArchivePassword.length == 0)
				mergedArchivePassword = obj.archivePassword;
			else
				enforce(mergedArchivePassword == obj.archivePassword,
					"Mismatching archive password");
		}
		if (obj.archiveSpecs !is null)
		{
			if (mergedArchiveSpecs is null)
				mergedArchiveSpecs = obj.archiveSpecs;
			else
				enforce(toJSONString(mergedArchiveSpecs)
					== toJSONString(obj.archiveSpecs), "Mismatching ArchiveSpecs");
		}
		mergedArchiveIndexKnown = mergedArchiveIndexKnown
			|| obj.archiveIndexKnown;
		mergedArchiveIndexDeep = mergedArchiveIndexDeep
			|| obj.archiveIndexDeep;
		if (obj.archiveScanCursor > mergedArchiveScanCursor)
			mergedArchiveScanCursor = obj.archiveScanCursor;
	}

	auto newobj = (objs[0]).dup;
	newobj.fileType = mergedFileType;
	newobj.mediaInfoSig = mergedMediaInfo is null ? null : mergedMediaInfo.dup();
	newobj.torrentInfo = mergedTorrentInfo is null
		? null : mergedTorrentInfo.dup();
	newobj.archivePassword = mergedArchivePassword;
	newobj.archiveSpecs = null;
	if (mergedArchiveSpecs !is null)
		foreach (entry; mergedArchiveSpecs)
			newobj.archiveSpecs ~= entry is null ? null : entry.dup();
	newobj.archiveIndexKnown = mergedArchiveIndexKnown;
	newobj.archiveIndexDeep = mergedArchiveIndexDeep;
	newobj.archiveScanCursor = mergedArchiveIndexDeep
		? 0 : mergedArchiveScanCursor;

	foreach (o; objs[1 .. $])
		newobj.fileSpecs ~= o.fileSpecs;
	/* Remove all duplicate references, not only adjacent ones. The inputs are
	 * concatenated from independently ordered lists. */
	FileSpec[] uniqueSpecs;
	bool[string] seenNames;
	foreach (spec; newobj.fileSpecs)
	{
		if (spec is null || (spec.fileName in seenNames) !is null)
			continue;
		seenNames[spec.fileName] = true;
		uniqueSpecs ~= spec;
	}
	newobj.fileSpecs = uniqueSpecs;
	return newobj;
}

/** Set invalidate flag on a range of blobs
 *
 * Params:
 *   objs = Set of objects to invalidate
 */
void invalidateDataClassObjs(NamedBinaryBlob[] objs)
{
	foreach (o; objs)
		o.fileSpecs = [];
}

/** Remove orphaned records whose filesystem references are all unavailable.
 *
 * Params:
 *   objs = Records to filter.
 * Returns: Records with at least one existing file reference. Use only when the
 *     caller explicitly intends missing-file cleanup.
 */
NamedBinaryBlob[] cleanupDataClassObjs(NamedBinaryBlob[] objs)
{
	import std.array;
	import std.algorithm : filter;

	alias matcher = (a) => !a.isBlobOrphaned;
	auto valobjs = objs.filter!(matcher);
	return valobjs.array;
}

/** Remove only records explicitly invalidated by duplicate merging.
 *
 * Unlike `cleanupDataClassObjs`, this helper does not test filesystem
 * existence. Callers can preserve unavailable source references unless the
 * user explicitly requested missing-file removal.
 *
 * Params:
 *     objs = Blob records to filter.
 * Returns: The non-null records that still have at least one file reference.
 */
NamedBinaryBlob[] cleanupInvalidatedDataClassObjs(NamedBinaryBlob[] objs)
{
	import std.array : array;
	import std.algorithm : filter;

	return objs.filter!(blob => blob !is null && blob.fileSpecs.length > 0).array;
}

/** Combined unit test for merge operaton
 *
 *
 */
@("mergeDataClassObjects and misc")
unittest
{
	import std.stdio : File;

	string[] filenames = [
		"test/dummy-subtitle-file.srt", "test/dummy-subtitle-file-copy.srt"
	];

	// Create 2 blobs
	auto fh = File(filenames[0]);
	auto dco1 = new NamedBinaryBlob(filenames[0], fh.size, SysTime(4_237_892));
	updateDigests(dco1, null);
	updateMediaInfo(dco1);
	updateFileType(dco1);
	auto dco2 = new NamedBinaryBlob(filenames[1], fh.size, SysTime(8_237_892));
	updateDigests(dco2, null);
	updateMediaInfo(dco2);
	updateFileType(dco2);

	// Merge objs
	auto dcobjs1 = [dco1, dco2];
	auto mdco = mergeDataClassObjects(dcobjs1);
	assert(mdco);
	assert(mdco.mediaInfoSig);
	assert(mdco.fileSpecs.length == 2);

	auto withoutMedia = dco1.dup;
	withoutMedia.mediaInfoSig = null;
	auto mergedWithLaterMedia = mergeDataClassObjects([withoutMedia, dco2]);
	assert(mergedWithLaterMedia.mediaInfoSig !is null);

	auto firstWithoutMetadata = dco1.dup;
	firstWithoutMetadata.fileType = null;
	firstWithoutMetadata.mediaInfoSig = null;
	firstWithoutMetadata.torrentInfo = null;
	firstWithoutMetadata.archivePassword = "";
	firstWithoutMetadata.archiveSpecs = null;
	firstWithoutMetadata.archiveIndexKnown = false;
	firstWithoutMetadata.archiveIndexDeep = false;
	auto laterWithMetadata = dco2.dup;
	laterWithMetadata.fileType = "later/file-type";
	laterWithMetadata.torrentInfo = new TorrentInfo();
	laterWithMetadata.torrentInfo.name = "later torrent";
	laterWithMetadata.archivePassword = "later password";
	laterWithMetadata.archiveSpecs = [
		new ArchiveSpec("member.txt", 1, "", CheckSums())
	];
	laterWithMetadata.archiveIndexKnown = true;
	laterWithMetadata.archiveIndexDeep = true;
	auto mergedMetadata = mergeDataClassObjects(
		[firstWithoutMetadata, laterWithMetadata]);
	assert(mergedMetadata.fileType == "later/file-type");
	assert(mergedMetadata.mediaInfoSig !is null);
	assert(mergedMetadata.torrentInfo !is null);
	assert(mergedMetadata.torrentInfo.name == "later torrent");
	assert(mergedMetadata.archivePassword == "later password");
	assert(mergedMetadata.archiveSpecs.length == 1);
	assert(mergedMetadata.archiveSpecs[0].fileName == "member.txt");
	assert(mergedMetadata.archiveIndexKnown);
	assert(mergedMetadata.archiveIndexDeep);

	auto conflictingFileType = laterWithMetadata.dup;
	conflictingFileType.fileType = "conflicting/file-type";
	assertThrown!Exception(mergeDataClassObjects(
		[laterWithMetadata, conflictingFileType]));
	auto conflictingPassword = laterWithMetadata.dup;
	conflictingPassword.archivePassword = "conflicting password";
	assertThrown!Exception(mergeDataClassObjects(
		[laterWithMetadata, conflictingPassword]));
	auto conflictingTorrent = laterWithMetadata.dup;
	conflictingTorrent.torrentInfo = new TorrentInfo();
	conflictingTorrent.torrentInfo.name = "conflicting torrent";
	assertThrown!Exception(mergeDataClassObjects(
		[laterWithMetadata, conflictingTorrent]));
	auto conflictingArchive = laterWithMetadata.dup;
	conflictingArchive.archiveSpecs = [
		new ArchiveSpec("other-member.txt", 1, "", CheckSums())
	];
	assertThrown!Exception(mergeDataClassObjects(
		[laterWithMetadata, conflictingArchive]));

	// Test fixups for (de)serialisation
	auto dcobjs2 = fixupDataClassArrayOut(dcobjs1);
	auto dcobjs3 = fixupDataClassArrayIn(dcobjs2);

	// test deletion of nodes from array
	invalidateDataClassObjs(dcobjs3);
	auto dcobj4 = cleanupDataClassObjs(dcobjs3);
	assert(dcobj4.length == 0);
}

@("legacy physical paths keep literal exclamation marks")
unittest
{
    auto blob = new NamedBinaryBlob();
    blob.fileSpecsUseArchiveVirtualGrammar = false;
    auto spec = new FileSpec("dir!/sample!.zip", "");
    assert(blob.physicalPathForSpec(spec) == "dir!/sample!.zip");
}
