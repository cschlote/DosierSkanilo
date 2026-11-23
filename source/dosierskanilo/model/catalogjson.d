/** JSON catalog serialization, deserialization, and migration to JSON v5.
 *
 * The wrapper format is read through the fixup helpers and written with the
 * streaming writer. Records are returned in the in-memory `NamedBinaryBlob`
 * representation defined in `dosierskanilo.model.namedbinaryblob`.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo.model.catalogjson;

import std.algorithm;
import std.array;
import std.datetime : Clock, dur;
import std.datetime.systime : SysTime;
import std.exception : assertThrown, enforce;
import jsonizer;
import dosierarkivo;
import dosierarkivo.archive : appendArchiveVirtualPath,
    escapeArchiveVirtualPath, nativePathToStoragePath,
    normalizeArchiveEntryPath, parseArchiveVirtualPath;
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

version (unittest)
{
	/// Path to the version-0 JSON catalog fixture.
	enum json_file_v0 = "./test/json_file_v0.json";
	/// Path to the version-1 JSON catalog fixture.
	enum json_file_v1 = "./test/json_file_v1.json";
	/// Path to the version-2 JSON catalog fixture.
	enum json_file_v2 = "./test/json_file_v2.json";
	/// Path to the version-2 archive JSON catalog fixture.
	enum json_file_v2_archive = "./test/json_file_v2_archive.json";
	/// Path to the version-2 torrent JSON catalog fixture.
	enum json_file_v2_torrent = "./test/json_file_v2_torrent.json";
	/// Contents of the version-0 JSON catalog fixture.
	auto test_json_v0 = import(json_file_v0);
	/// Contents of the version-1 JSON catalog fixture.
	auto test_json_v1 = import(json_file_v1);
	/// Contents of the version-2 JSON catalog fixture.
	auto test_json_v2 = import(json_file_v2);
	/// Contents of the version-2 archive JSON catalog fixture.
	auto test_json_v2_archive = import(json_file_v2_archive);
	/// Contents of the version-2 torrent JSON catalog fixture.
	auto test_json_v2_torrent = import(json_file_v2_torrent);
}

/** Fixup legacy fields in NamedBinaryBlob array for deserialization
 *
 * Params:
 *   dataArray = Array of NamedBinaryBlob objects to process
 *   progressCallBack = optional callback for deserialization progress.
 * Returns: Updated array of NamedBinaryBlob objects
 */
NamedBinaryBlob[] fixupDataClassArrayIn(NamedBinaryBlob[] dataArray,
	ProgressCallBack* progressCallBack = null)
{
	// -- Fixup legacy fields ---------------------------
	auto lastProgress = Clock.currTime;
	foreach (index, ref obj; dataArray)
	{
		// -- Fixup legacy filename field ---------------------------
		/* The same data blob may have been stored with either a single
		 * filename (fileName) or multiple filenames (fileNames).
		 * We convert all entries to use the fileNames array.
		 */
		/* Capture the timestamp before clearing the legacy field so a record
		 * that carries both `fileName` and `fileNames` keeps it for every
		 * reference. */
		const legacyModifiedAt = obj.timeLastModified;
		if (obj.fileName.empty == false)
		{
			obj.fileSpecs ~= new FileSpec(obj.fileName, legacyModifiedAt);
			obj.fileName = null;
			obj.timeLastModified = null;
		}
		// -- Fixup legacy 2 - filenames and dates must be together --
		if (obj.fileNames.empty == false)
		{
			foreach (fn; obj.fileNames)
				obj.fileSpecs ~= new FileSpec(fn, legacyModifiedAt);
			obj.fileNames = [];
			obj.timeLastModified = null;
		}

		// -- Fixup legacy digest fields ---------------------------
		if (obj.md5sum_b64 !is null && !obj.md5sum_b64.empty)
		{
			obj.checkSums.md5sum_b64 = obj.md5sum_b64;
		}
		if (obj.sha1sum_b64 !is null && !obj.sha1sum_b64.empty)
		{
			obj.checkSums.sha1sum_b64 = obj.sha1sum_b64;
		}
		if (obj.xxh64sum_b64 !is null && !obj.xxh64sum_b64.empty)
		{
			obj.checkSums.xxh64sum_b64 = obj.xxh64sum_b64;
		}

		// -- Fixup legacy mediaInfo field ---------------------------
		if (obj.mediaInfo !is null && obj.mediaInfo.length > 0)
		{
			obj.mediaInfoSig = parseMediaInfoSignature(obj.mediaInfo);
		}

		// -- Fixup some broken entries ---------------------------
		if (obj.mediaInfoSig !is null)
		{
			with (obj.mediaInfoSig)
			{
				foreach (v; imageStreams)
					if (v !is null && v.index == -1)
						v.index = 0;
				foreach (v; videoStreams)
					if (v !is null && v.index == -1)
						v.index = 0;
				foreach (v; audioStreams)
					if (v !is null && v.index == -1)
						v.index = 0;
				foreach (v; textStreams)
					if (v !is null && v.index == -1)
						v.index = 0;
			}
		}
		normalizeJpegImageMediaInfo(obj);
		//-- filter empty mediaInfoSig ---------------------------
		if (obj.mediaInfoSig !is null && obj.mediaInfoSig.empty)
		{
			obj.mediaInfoSig = null;
		}

		// -- Fixup broken torrent entries ---------------------------
		if ((obj.torrentInfo !is null) && (obj.torrentInfo.magnetURI.empty))
		{
			obj.torrentInfo = null;
		}
		if (progressCallBack !is null
			&& (index == 0 || index + 1 == dataArray.length
				|| Clock.currTime - lastProgress > dur!"msecs"(250)))
		{
			progressCallBack.report(index + 1, dataArray.length);
			lastProgress = Clock.currTime;
		}
	}

	return dataArray;
}

/** Fixup NamedBinaryBlob array before serialization
 *
 * Params:
 *   dataArray = Array of NamedBinaryBlob objects to process
 *   progressCallBack = optional callback for serialization progress.
 * Returns: Updated array of NamedBinaryBlob objects
 */
NamedBinaryBlob[] fixupDataClassArrayOut(NamedBinaryBlob[] dataArray,
	ProgressCallBack* progressCallBack = null)
{
	// -- Fixup legacy fields ---------------------------
	auto lastProgress = Clock.currTime;
	foreach (index, ref obj; dataArray)
	{
		// -- Clear legacy filename field ---------------------------
		if (obj.fileSpecs.length > 1)
		{
			obj.fileName = "";
			obj.timeLastModified = "";
		}
		// -- We have just a single name, setup the single filename --
		else if (obj.fileSpecs.length == 1)
		{
			obj.fileName = obj.fileSpecs[0].fileName;
			obj.timeLastModified = obj.fileSpecs[0].timeLastModified;
			obj.fileSpecs = [];
		}
		// -- No reference at all, keep the legacy fields empty ------
		else
		{
			obj.fileName = "";
			obj.timeLastModified = "";
		}
		if (obj.fileNames.length != 0)
			throw new CatalogFormatException(
				"Internal error: fileNames must be empty before serialization.");

		// -- Clear legacy digest fields ---------------------------
		obj.md5sum_b64 = null;
		obj.sha1sum_b64 = null;
		obj.xxh64sum_b64 = null;

		// -- Clear legacy mediaInfo field ---------------------------
		obj.mediaInfo = null;

		normalizeJpegImageMediaInfo(obj);

		if (obj.mediaInfoSig !is null && obj.mediaInfoSig.empty)
		{
			obj.mediaInfoSig = null;
		}

		// -- Fixup broken torrent entries ---------------------------
		if ((obj.torrentInfo !is null) && (obj.torrentInfo.magnetURI.empty))
		{
			obj.torrentInfo = null;
		}
		if (progressCallBack !is null
			&& (index == 0 || index + 1 == dataArray.length
				|| Clock.currTime - lastProgress > dur!"msecs"(250)))
		{
			progressCallBack.report(index + 1, dataArray.length);
			lastProgress = Clock.currTime;
		}
	}

	return dataArray;
}

@("fixupDataClassArrayOut")
unittest
{
	auto mis0 = new NamedBinaryBlob("file1", 1234, SysTime(1_234_567));
	auto mis1 = new NamedBinaryBlob(["file2", "file3"], 2345, SysTime(1_234_567));
	auto dca = fixupDataClassArrayOut([mis0, mis1]);
	assert(dca[0].fileName == "file1");
	assert(dca[0].timeLastModified == SysTime(1_234_567).toISOExtString);
	assert(dca[0].fileSpecs.length == 0);
	assert(dca[1].fileName == "");
	assert(dca[1].timeLastModified == "");
	assert(dca[1].fileSpecs.length == 2);
}

/** Deserialize a JSON string into the global wrapper structure.
 *
 * Params:
 *   serializedData = JSON string with serialized NamedBinaryBlob data
 *   progressCallBack = optional callback for deserialization progress.
 * Returns:
 *   wrapper object with deserialized NamedBinaryBlob data and metadata
 */
NamedBinaryBlobCatalog deserializeDataClassJsonWrapperString(const string serializedData,
	ProgressCallBack* progressCallBack = null)
{
	NamedBinaryBlobCatalog wrapper;

	if (serializedData.length == 0)
		return wrapper;

	// Check for new JSON object format
	if (serializedData[0] != '[')
	{
		logLineVerbose("  Reading into NamedBinaryBlobCatalog object (new format)...");
		import std.json : JSONType, parseJSON;
		import std.conv : to;

		auto json = parseJSON(serializedData);
		if (json.type != JSONType.object)
			throw new CatalogFormatException("Unexpected JSON root type.");

		wrapper.dataVersion = DATA_CLASS_VERSION3;
		if ("dataVersion" in json.object)
			wrapper.dataVersion = cast(ulong) json.object["dataVersion"].integer;
		if ("mediaInfoVersion" in json.object)
			wrapper.mediaInfoVersion = json.object["mediaInfoVersion"].str;
		if ("fileUtilityVersion" in json.object)
			wrapper.fileUtilityVersion = json.object["fileUtilityVersion"].str;
		if ("dataArray" in json.object)
			wrapper.dataArray = fromJSONString!(NamedBinaryBlob[])(json.object["dataArray"].toString);

		if (wrapper.dataVersion == DATA_CLASS_VERSION1)
			wrapper.dataVersion = DATA_CLASS_VERSION2;

		if (wrapper.dataVersion != DATA_CLASS_VERSION2
			&& wrapper.dataVersion != DATA_CLASS_VERSION3
			&& wrapper.dataVersion != DATA_CLASS_VERSION4
			&& wrapper.dataVersion != DATA_CLASS_VERSION5)
			throw new CatalogFormatException("Data version mismatch, expected "
				~ to!string(DATA_CLASS_VERSION2) ~ ", " ~ to!string(
				DATA_CLASS_VERSION3) ~ ", " ~ to!string(DATA_CLASS_VERSION4)
				~ " or " ~ to!string(DATA_CLASS_VERSION5) ~ ", got "
				~ to!string(wrapper.dataVersion));
	}
	// Check for old plain array JSON
	else if (serializedData[0] == '[')
	{
		logLineVerbose("  Reading directly into NamedBinaryBlob[] array (legacy format)...");
		wrapper.dataArray = fromJSONString!(NamedBinaryBlob[])(serializedData);
		wrapper.dataVersion = DATA_CLASS_VERSION3;
	}
	// Shouldn't happen
	else
		throw new CatalogFormatException("Unknown JSON format.");

	wrapper.dataArray = fixupDataClassArrayIn(wrapper.dataArray, progressCallBack);
	if (wrapper.dataVersion == DATA_CLASS_VERSION5)
		foreach (blob; wrapper.dataArray)
			if (blob !is null)
				blob.fileSpecsUseArchiveVirtualGrammar = true;
	logFLineVerbose("  got %d entries in array after deserialization() of archive data.", wrapper.dataArray.length);

	return wrapper;
}

/** Deserialize a JSON string and return NamedBinaryBlob[] array
 *
 * Params:
 *   serializedData = JSON string with serialized NamedBinaryBlob data
 * Returns:
 *   array of deserialized NamedBinaryBlob objects
 */
NamedBinaryBlob[] deserializeDataClassJsonString(const string serializedData)
{
	return deserializeDataClassJsonWrapperString(serializedData).dataArray;
}

/** Deserialize a JSON file and return NamedBinaryBlobCatalog object.
 *
 * Params:
 *   fileName = the name of JSON file to read.
 *   progressCallBack = optional callback for deserialization progress.
 * Returns:
 *   wrapper with deserialized NamedBinaryBlob data and metadata, or an empty
 *   wrapper when the file is missing.
 * Throws:
 *   `CatalogFormatException` for unsupported versions or malformed catalog data.
 */
NamedBinaryBlobCatalog deserializeDataClassJsonWrapperFile(string fileName,
	ProgressCallBack* progressCallBack = null)
{
	import std.file : exists, readText;

	logFLineVerbose("Read serialized data from JSON file %s", fileName);
	if (!exists(fileName))
		return NamedBinaryBlobCatalog(DATA_CLASS_VERSION3, []);

	const string serializedData = readText(fileName);
	return deserializeDataClassJsonWrapperString(serializedData, progressCallBack);
}


@("deserializeDataClassJsonString")
unittest
{
	auto dca0 = deserializeDataClassJsonString(test_json_v0);
	assert(dca0.length == 3);

	auto dca1 = deserializeDataClassJsonString(test_json_v1);
	assert(dca1.length == 3);

	auto dca2 = deserializeDataClassJsonString(test_json_v2);
	assert(dca2.length == 3);

	auto s0 = sortDataClassArrayByFileName(dca0);
	auto s1 = sortDataClassArrayByFileName(dca1);
	auto s2 = sortDataClassArrayByFileName(dca2);
	foreach (index; 0 .. s0.length)
	{
		assert(s0[index].toString == s1[index].toString, s0[index].toString ~ " != " ~ s1[index].toString);
		assert(s0[index].toString == s2[index].toString, s0[index].toString ~ " != " ~ s2[index].toString);
	}
}

/** Deserialize a JSON file and return NamedBinaryBlob[] array
 *
 * Params:
 *   fileName = the name of JSON file to read.
 *   verbose = retained for source compatibility; logging is controlled by
 *     `dosierskanilo.logging`.
 * Returns:
 *   array of deserialized NamedBinaryBlob objects, or an empty array when the
 *   file is missing.
 * Throws:
 *   `CatalogFormatException` for unsupported versions or malformed catalog data.
 */
NamedBinaryBlob[] deserializeDataClassJsonFile(string fileName, bool verbose = false)
{
	import std.file : exists, readText;

	logFLineVerbose("Read serialized data from JSON file %s", fileName);
	//enforce(exists(fileName), "File %s does not exist!".format(fileName));
	if (!exists(fileName))
		return [];

	logFLine("  reading file '%s' into the serializer archive container", fileName);
	const string serializedData = readText(fileName);

	return deserializeDataClassJsonString(serializedData);
}

/** Convert a file name to the canonical JSON-v5 path grammar.
 *
 * Params:
 *     fileName = File name to canonicalize.
 *     fromLegacyVersion = Whether the name comes from a pre-v5 catalog and
 *         therefore needs native-to-storage escaping.
 * Returns: Canonical escaped path, with virtual members re-appended.
 */
private string canonicalV5FilePath(string fileName, bool fromLegacyVersion)
{
	import std.string : replace;

	if (fromLegacyVersion)
		return escapeArchiveVirtualPath(nativePathToStoragePath(fileName));

	const auto parsed = parseArchiveVirtualPath(fileName);
	auto result = escapeArchiveVirtualPath(parsed.physicalPath);
	foreach (entry; parsed.entries)
		result = appendArchiveVirtualPath(result, entry.relativePath,
			entry.hasOccurrence ? entry.occurrence : size_t.max);
	return result;
}

/** Build the identity key used to count archive entries with the same path.
 *
 * Params:
 *     path = Normalized archive member path.
 * Returns: A key prefixed with `safe\0`, the only identity class this model
 *     tracks.
 */
private string archiveVirtualIdentityKey(string path)
{
	return "safe\0" ~ path;
}

/** Append virtual member blobs for one archive level, recursing into nested ones.
 *
 * Params:
 *     result = Output array that receives the generated member blobs.
 *     entries = Archive entries to convert.
 *     containerPath = Canonical virtual path of the containing archive.
 *     depth = Current nesting level; used to enforce the depth limit.
 * Throws: `Exception` when nesting exceeds the supported depth.
 */
private void appendArchiveMemberBlobs(ref NamedBinaryBlob[] result,
	ArchiveSpec[] entries, string containerPath, size_t depth = 0)
{
	enforce(depth < 32,
		"Nested archive conversion exceeds the maximum depth.");
	size_t[string] pathCounts;
	foreach (entry; entries)
	{
		if (entry is null)
			continue;
		bool safe;
		bool isDirectory;
		const auto path = normalizeArchiveEntryPath(entry.fileName, safe,
			isDirectory);
		if (safe && !isDirectory)
		{
			const auto key = archiveVirtualIdentityKey(path);
			pathCounts[key] = pathCounts.get(key, 0) + 1;
		}
	}

	size_t[string] nextOccurrence;
	foreach (entry; entries)
	{
		if (entry is null)
			continue;
		bool safe;
		bool isDirectory;
		const auto path = normalizeArchiveEntryPath(entry.fileName, safe,
			isDirectory);
		if (!safe || isDirectory)
			continue;

		const auto key = archiveVirtualIdentityKey(path);
		size_t occurrence;
		if (entry.hasIndexIdentity)
			occurrence = entry.occurrence;
		else
			occurrence = nextOccurrence.get(key, 0);
		nextOccurrence[key] = occurrence + 1;
		const bool includeOccurrence = pathCounts.get(key, 0) > 1
			|| occurrence > 0;
		const auto memberPath = appendArchiveVirtualPath(containerPath, path,
			includeOccurrence ? occurrence : size_t.max);

		auto member = new NamedBinaryBlob();
		member.fileSize = entry.fileSize;
		member.checkSums = entry.checkSums;
		member.fileType = entry.fileType;
		if (entry.mediaInfoSig !is null)
			member.mediaInfoSig = entry.mediaInfoSig.dup;
		member.fileSpecs = [new FileSpec(memberPath, entry.timeLastModified)];
		member.archivePassword = entry.archivePassword;
		member.archiveIndexKnown = entry.nestedEntries !is null
			|| entry.archivePassword.length > 0;
		member.archiveIndexDeep = entry.nestedEntries !is null
			&& archiveEntriesHaveCompleteChecksums(entry.nestedEntries);
		member.fileSpecsUseArchiveVirtualGrammar = true;
		result ~= member;

		if (entry.nestedEntries !is null)
			appendArchiveMemberBlobs(result, entry.nestedEntries, memberPath,
				depth + 1);
	}
}

/** Convert legacy nested ArchiveSpec trees into ordinary JSON-v5 blob references.
 *
 * Params:
 *     blobs = Blob records to normalize; `null` entries are skipped.
 *     sourceAlreadyV5 = Whether paths already use the V5 grammar rather than a
 *         legacy native-path spelling.
 * Returns: A newly sorted record array containing the normalized blobs and
 *     generated archive-member references.
 * Throws: `Exception` when an archive index has no containing file reference.
 */
private NamedBinaryBlob[] normalizeV5Catalog(NamedBinaryBlob[] blobs,
	bool sourceAlreadyV5)
{
	NamedBinaryBlob[] records;
	foreach (blob; blobs)
	{
		if (blob is null)
			continue;
		blob = fixupDataClassArrayIn([blob])[0];
		foreach (spec; blob.fileSpecs)
			if (spec !is null && spec.fileName.length > 0)
				spec.fileName = canonicalV5FilePath(spec.fileName,
					!sourceAlreadyV5);
		blob.fileSpecsUseArchiveVirtualGrammar = true;

		auto archiveEntries = blob.archiveSpecs;
		if (archiveEntries !is null && blob.fileSpecs.length == 0)
			throw new Exception("An archive index cannot be promoted without a "
				~ "containing FileSpec reference.");
		if (archiveEntries !is null)
		{
			blob.archiveIndexKnown = true;
			if (blob.archiveScanCursor == 0)
				blob.archiveIndexDeep = archiveEntriesHaveCompleteChecksums(
					archiveEntries);
			blob.archiveSpecs = null;
		}
		records ~= blob;

		if (archiveEntries !is null)
			foreach (containerSpec; blob.fileSpecs)
				if (containerSpec !is null && containerSpec.fileName.length > 0)
					appendArchiveMemberBlobs(records, archiveEntries,
						containerSpec.fileName);
	}

	return sortDataClassArrayByFileName(records);
}

/** Report whether every regular file entry in an archive tree has full digests.
 *
 * Params:
 *     entries = Archive entries to inspect, including nested levels.
 * Returns: `true` when all non-directory entries carry complete checksums.
 */
private bool archiveEntriesHaveCompleteChecksums(ArchiveSpec[] entries)
{
	foreach (entry; entries)
	{
		if (entry is null)
			continue;
		bool safe;
		bool isDirectory;
		normalizeArchiveEntryPath(entry.fileName, safe, isDirectory);
		if (!safe || isDirectory)
			continue;
		if (!entry.checkSums.hasDigests)
			return false;
		if (entry.nestedEntries !is null
			&& !archiveEntriesHaveCompleteChecksums(entry.nestedEntries))
			return false;
	}
	return true;
}

/** Strip legacy fields and normalize optional metadata before V5 serialization.
 *
 * Params:
 *     dataArray = Blob records to normalize in place.
 * Returns: The same array, for chaining.
 */
private NamedBinaryBlob[] fixupDataClassArrayOutV5(
	NamedBinaryBlob[] dataArray)
{
	foreach (ref obj; dataArray)
	{
		obj.fileName = null;
		obj.timeLastModified = null;
		obj.fileNames = null;
		obj.md5sum_b64 = null;
		obj.sha1sum_b64 = null;
		obj.xxh64sum_b64 = null;
		obj.mediaInfo = null;
		normalizeJpegImageMediaInfo(obj);
		if (obj.mediaInfoSig !is null && obj.mediaInfoSig.empty)
			obj.mediaInfoSig = null;
		if (obj.torrentInfo !is null && obj.torrentInfo.magnetURI.empty)
			obj.torrentInfo = null;
	}
	return dataArray;
}

/** Promote a deserialized version 2..5 catalog to the canonical JSON-v5 model.
 *
 * Version 1 is normalized during deserialization. Unsupported versions throw.
 *
 * Params:
 *   wrapper = catalog to normalize in place.
 * Throws:
 *   `Exception` when `wrapper.dataVersion` is outside 2..5.
 */
void upgradeDataClassCatalogToV5(ref NamedBinaryBlobCatalog wrapper)
{
	if (wrapper.dataVersion < DATA_CLASS_VERSION2
		|| wrapper.dataVersion > DATA_CLASS_VERSION5)
		throw new Exception("Unsupported JSON catalog version.");
	const bool sourceAlreadyV5 = wrapper.dataVersion == DATA_CLASS_VERSION5;
	wrapper.dataArray = normalizeV5Catalog(wrapper.dataArray, sourceAlreadyV5);
	wrapper.dataVersion = DATA_CLASS_VERSION5;
}

/** Normalize and serialize a catalog as a JSON-v5 file.
 *
 * The wrapper is promoted to version 5, runtime metadata is refreshed, and
 * records are sorted and deduplicated before streaming. The passed wrapper is
 * mutated: `dataVersion` becomes 5 and `dataArray` reflects the normalized
 * records.
 *
 * Params:
 *   fileName = destination JSON file.
 *   wrapper = catalog to normalize and write.
 *   pretty = indent the serialized JSON for human reading.
 * Throws:
 *   `Exception` for unsupported catalog versions or serialization failures.
 */
void serializeDataClassWrapperFile(string fileName, ref NamedBinaryBlobCatalog wrapper,
	bool pretty = false)
{
	import std.conv : to;
	import std.json : JSONValue;
	import std.stdio : File;
	import std.string : replace;
	import jsonizer.tojson : PrettyJson, toJSONString;

	logFLineVerbose("Generate JSON data and write it to file %s", fileName);
	if (wrapper.dataVersion == 0)
		wrapper.dataVersion = DATA_CLASS_VERSION5;
	upgradeDataClassCatalogToV5(wrapper);
	wrapper.refreshRuntimeMetadata();

	logFLineVerbose("  sort and uniq serialized array by their filenames (use a range)");
	auto sortedDeserializedData_rng = sortDataClassArrayByFileName(wrapper.dataArray);
	auto uniqSortedDeserializedData = uniqDataClassArrayByFileName(sortedDeserializedData_rng);
	wrapper.dataArray = fixupDataClassArrayOutV5(uniqSortedDeserializedData);
	scope (exit)
	{
		wrapper.dataArray = fixupDataClassArrayIn(wrapper.dataArray);
		foreach (blob; wrapper.dataArray)
			if (blob !is null)
				blob.fileSpecsUseArchiveVirtualGrammar = true;
	}

	/* Stream the catalog so memory use stays bounded by one blob instead of
	 * materializing the complete JSON tree and string for millions of rows. */
	auto file = File(fileName, "wb");
	scope (exit)
		file.close();
	if (pretty)
	{
		file.write("{\n    \"dataVersion\": ");
		file.write(wrapper.dataVersion.to!string);
		if (wrapper.mediaInfoVersion.length > 0)
		{
			file.write(",\n    \"mediaInfoVersion\": ");
			file.write(JSONValue(wrapper.mediaInfoVersion).toString);
		}
		if (wrapper.fileUtilityVersion.length > 0)
		{
			file.write(",\n    \"fileUtilityVersion\": ");
			file.write(JSONValue(wrapper.fileUtilityVersion).toString);
		}
		file.write(",\n    \"dataArray\": [\n");
		foreach (index, blob; wrapper.dataArray)
		{
			const text = blob is null ? "null"
				: toJSONString(blob, PrettyJson.yes);
			file.write("        ");
			file.write(text.replace("\n", "\n        "));
			file.write(index + 1 < wrapper.dataArray.length ? ",\n" : "\n");
		}
		file.write("    ]\n}\n");
	}
	else
	{
		file.write("{\"dataVersion\":");
		file.write(wrapper.dataVersion.to!string);
		if (wrapper.mediaInfoVersion.length > 0)
		{
			file.write(",\"mediaInfoVersion\":");
			file.write(JSONValue(wrapper.mediaInfoVersion).toString);
		}
		if (wrapper.fileUtilityVersion.length > 0)
		{
			file.write(",\"fileUtilityVersion\":");
			file.write(JSONValue(wrapper.fileUtilityVersion).toString);
		}
		file.write(",\"dataArray\":[");
		foreach (index, blob; wrapper.dataArray)
		{
			if (index > 0)
				file.write(",");
			if (blob is null)
				file.write("null");
			else
				file.write(toJSONString(blob, PrettyJson.no));
		}
		file.write("]}");
	}
	file.flush();
	file.sync();
}

@("archive scan cursor survives JSON serialization")
unittest
{
    import std.conv : to;
    import std.file : exists, remove, tempDir;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    const path = buildPath(tempDir(), "archive-cursor-" ~ randomUUID().toString()
        ~ ".json");
    scope (exit)
        if (exists(path))
            remove(path);
    auto blob = new NamedBinaryBlob();
    blob.fileSize = 42;
    blob.fileSpecs = [new FileSpec("bundle.7z", "")];
    blob.archiveIndexKnown = true;
    blob.archiveIndexDeep = false;
    blob.archiveScanCursor = 17;
    auto catalog = NamedBinaryBlobCatalog(DATA_CLASS_VERSION5, [blob]);
    serializeDataClassWrapperFile(path, catalog);
    auto loaded = deserializeDataClassJsonWrapperFile(path);
    assert(loaded.dataArray.length == 1);
    assert(loaded.dataArray[0].archiveScanCursor == 17,
        loaded.dataArray[0].archiveScanCursor.to!string);
    assert(loaded.dataArray[0].archiveIndexKnown);
    assert(!loaded.dataArray[0].archiveIndexDeep);
}

@("serializeDataClassWrapperFile writes compact JSON unless pretty is requested")
unittest
{
	import std.file : exists, readText, remove, tempDir;
	import std.path : buildPath;
	import std.uuid : randomUUID;

	const token = randomUUID().toString();
	const compactPath = buildPath(tempDir(), "compact-" ~ token ~ ".json");
	const prettyPath = buildPath(tempDir(), "pretty-" ~ token ~ ".json");
	scope (exit)
	{
		if (exists(compactPath))
			remove(compactPath);
		if (exists(prettyPath))
			remove(prettyPath);
	}
	auto compactCatalog = NamedBinaryBlobCatalog(DATA_CLASS_VERSION5,
		[new NamedBinaryBlob("sample.txt", 3, Clock.currTime)]);
	serializeDataClassWrapperFile(compactPath, compactCatalog);
	auto prettyCatalog = NamedBinaryBlobCatalog(DATA_CLASS_VERSION5,
		[new NamedBinaryBlob("sample.txt", 3, Clock.currTime)]);
	serializeDataClassWrapperFile(prettyPath, prettyCatalog, true);
	const compact = readText(compactPath);
	const pretty = readText(prettyPath);
	assert(!compact.canFind('\n'));
	assert(pretty.canFind('\n'));
	assert(pretty.canFind("    \""));
}

@("streaming catalog writes round-trip thousands of records")
unittest
{
	import std.conv : to;
	import std.file : exists, remove, tempDir;
	import std.path : buildPath;
	import std.uuid : randomUUID;

	const path = buildPath(tempDir(), "streamed-catalog-"
		~ randomUUID().toString() ~ ".json");
	scope (exit)
		if (exists(path))
			remove(path);

	NamedBinaryBlob[] blobs;
	foreach (index; 0 .. 10_000)
	{
		auto blob = new NamedBinaryBlob("streamed-" ~ index.to!string ~ ".bin",
			cast(size_t) index + 1, Clock.currTime);
		blob.fileSpecs ~= new FileSpec(
			"media/streamed-" ~ index.to!string ~ ".bin", "");
		blobs ~= blob;
	}
	auto catalog = NamedBinaryBlobCatalog(DATA_CLASS_VERSION5, blobs);
	serializeDataClassWrapperFile(path, catalog);
	const auto loaded = deserializeDataClassJsonWrapperFile(path);
	assert(loaded.dataArray.length == blobs.length);
	assert(loaded.dataArray[0].getFirstFileName
		== "media/streamed-0.bin");
	assert(loaded.dataArray[$ - 1].getFirstFileName
		== "media/streamed-9999.bin");
}

@("JSON v5 promotes nested and duplicate archive members to virtual references")
unittest
{
	import std.file : exists, remove, tempDir;
	import std.path : buildPath;
	import std.uuid : randomUUID;

	const auto fileName = buildPath(tempDir(), "nested-archive-v5-"
		~ randomUUID().toString() ~ ".json");
	scope (exit)
		if (exists(fileName))
			remove(fileName);

	auto member = new ArchiveSpec("nested/readme.txt", 11, "",
		CheckSums("md5", "sha1", "xxh64"));
	auto duplicateMember = new ArchiveSpec("nested/readme.txt", 11, "",
		CheckSums("md5", "sha1", "xxh64"));
	auto deepMember = new ArchiveSpec("deep/readme!.txt", 5, "",
		CheckSums.init);
	auto nestedArchive = new ArchiveSpec("nested.zip", 64, "",
		CheckSums.init);
	nestedArchive.nestedEntries = [deepMember];
	auto blob = new NamedBinaryBlob();
	blob.fileSize = 256;
	blob.fileSpecs = [new FileSpec("container!.zip", "")];
	blob.archiveSpecs = [member, duplicateMember, nestedArchive];
	auto v4 = NamedBinaryBlobCatalog(DATA_CLASS_VERSION4, [blob]);
	serializeDataClassWrapperFile(fileName, v4);
	assert(v4.dataVersion == DATA_CLASS_VERSION5);
	auto loaded = deserializeDataClassJsonWrapperFile(fileName);
	assert(loaded.dataVersion == DATA_CLASS_VERSION5);
	assert(loaded.dataArray.length == 5);
	string[] virtualPaths;
	bool foundArchiveIndexMarker;
	foreach (record; loaded.dataArray)
	{
		foundArchiveIndexMarker = foundArchiveIndexMarker
			|| record.archiveIndexKnown;
		foreach (spec; record.fileSpecs)
			virtualPaths ~= spec.fileName;
	}
	assert(virtualPaths.canFind("container!!.zip"));
	assert(virtualPaths.canFind("container!!.zip!/nested/readme.txt!~0"));
	assert(virtualPaths.canFind("container!!.zip!/nested/readme.txt!~1"));
	assert(virtualPaths.canFind("container!!.zip!/nested.zip"));
	assert(virtualPaths.canFind("container!!.zip!/nested.zip!/deep/readme!!.txt"));
	assert(foundArchiveIndexMarker);
}

@("JSON v5 decodes escaped physical exclamation marks for filesystem access")
unittest
{
	import std.file : exists, getSize, remove, tempDir, write;
	import std.path : buildPath;
	import std.uuid : randomUUID;

	const auto token = randomUUID().toString();
	const auto physicalPath = buildPath(tempDir(), "physical-literal!-"
		~ token ~ ".txt");
	const auto jsonPath = buildPath(tempDir(), "physical-literal-json-"
		~ token ~ ".json");
	scope (exit)
	{
		if (exists(physicalPath))
			remove(physicalPath);
		if (exists(jsonPath))
			remove(jsonPath);
	}
	write(physicalPath, "v5 physical path");
	auto blob = new NamedBinaryBlob();
	blob.fileSize = cast(size_t) getSize(physicalPath);
	blob.fileSpecs = [new FileSpec(physicalPath, "")];
	auto emptyArchive = new NamedBinaryBlob();
	emptyArchive.fileSpecs = [new FileSpec("empty!.zip", "")];
	emptyArchive.archiveIndexKnown = true;
	auto catalog = NamedBinaryBlobCatalog(DATA_CLASS_VERSION3,
		[blob, emptyArchive]);
	serializeDataClassWrapperFile(jsonPath, catalog);
	auto loaded = deserializeDataClassJsonWrapperFile(jsonPath);
	assert(loaded.dataVersion == DATA_CLASS_VERSION5);
	assert(loaded.dataArray.length == 2);
	bool foundPhysicalPath;
	bool foundEmptyArchiveIndex;
	foreach (restored; loaded.dataArray)
	{
		foreach (spec; restored.fileSpecs)
			if (spec.fileName == escapeArchiveVirtualPath(physicalPath))
			{
				foundPhysicalPath = true;
				assert(restored.getFirstExistingFileName == physicalPath);
				assert(restored.hasFileName(physicalPath));
			}
		foundEmptyArchiveIndex = foundEmptyArchiveIndex
			|| restored.archiveIndexKnown;
	}
	assert(foundPhysicalPath && foundEmptyArchiveIndex);
}

@("deserializeDataClassJsonFile")
unittest
{
	import std.file : exists, readText, tempDir, getSize, getTimes, mkdirRecurse, rmdirRecurse;

	auto dca = deserializeDataClassJsonFile("./test/json_file_notexisting.json");
	assert(dca.length == 0);

	auto dca0 = deserializeDataClassJsonFile(json_file_v0);
	assert(dca0.length == 3);

	auto dca1 = deserializeDataClassJsonFile(json_file_v1);
	assert(dca1.length == 3);

	auto dca2 = deserializeDataClassJsonFile(json_file_v2);
	assert(dca2.length == 3);

	auto s0 = sortDataClassArrayByFileName(dca0);
	auto s1 = sortDataClassArrayByFileName(dca1);
	auto s2 = sortDataClassArrayByFileName(dca2);
	foreach (index; 0 .. s0.length)
	{
		assert(s0[index].toString == s1[index].toString, s0[index].toString ~ " != " ~ s1[index].toString);
		assert(s0[index].toString == s2[index].toString, s0[index].toString ~ " != " ~ s2[index].toString);
	}

	assertThrown!CatalogFormatException(deserializeDataClassJsonFile("./test/json_file_v1_wrongversion.json"), "No bumm?");
}

@("legacy JSON round-trip preserves catalog data")
unittest
{
	import std.conv : to;
	import std.file : exists, mkdirRecurse, readText, remove, rmdirRecurse, tempDir;
	import std.path : buildPath;
	import std.uuid : randomUUID;

	// Archive and torrent fixtures are excluded here: they use legacy nested
	// member storage (v4) that is flattened into normal blobs on save (v5),
	// so their record count changes across a round trip. They are covered by
	// the repository import/export tests instead.
	foreach (fixture; [
		"./test/json_file_v0.json",
		"./test/json_file_v1.json",
		"./test/json_file_v2.json"
	])
	{
		auto loaded = deserializeDataClassJsonFile(fixture);
		assert(loaded.length > 0, fixture);

		auto dir = buildPath(tempDir(), "dosierskanilo-roundtrip-" ~ randomUUID().toString());
		mkdirRecurse(dir);
		auto outPath = buildPath(dir, "roundtrip.json");
		scope (exit)
		{
			if (exists(outPath))
				remove(outPath);
			if (exists(dir))
				rmdirRecurse(dir);
		}

		auto wrapper = NamedBinaryBlobCatalog(DATA_CLASS_VERSION5, loaded);
		serializeDataClassWrapperFile(outPath, wrapper);

		auto reloaded = deserializeDataClassJsonFile(outPath);
		assert(reloaded.length == loaded.length, fixture);

		auto s1 = sortDataClassArrayByFileName(loaded);
		auto s2 = sortDataClassArrayByFileName(reloaded);
		foreach (index; 0 .. s1.length)
		{
			assert(s1[index].toString == s2[index].toString,
				fixture ~ ": record " ~ index.to!string ~ " changed after round-trip");
		}
	}
}

/** Serialize an array of NamedBinaryBlob classes
 *
 * Store the array data in a JSON file.
 * Params:
 *   fileName = The filename for the JSON
 *   dataArray = Array of NamedBinaryBlob objects to serialize
 */
void serializeDataClassArrayFile(string fileName, NamedBinaryBlob[] dataArray)
{
	auto wrapper = NamedBinaryBlobCatalog(DATA_CLASS_VERSION3, dataArray);
	serializeDataClassWrapperFile(fileName, wrapper);
}

version (unittest)
{
	/** Verify JSON round-tripping against an expected catalog fixture.
	 *
	 * Params:
	 *     fileName = JSON catalog text to deserialize.
	 *     expectedLength = Expected number of records.
	 *     expectedJsonFile = Path of the fixture to compare against.
	 */
	void testSerializeDataClassArrayFile(string fileName, int expectedLength, string expectedJsonFile)
	{
		import std.conv : to;
		import std.file : mkdirRecurse, readText, remove, tempDir;
		import std.json : JSONValue, parseJSON;
		import std.path : buildPath;
		import std.uuid : randomUUID;

		auto dca1 = deserializeDataClassJsonString(fileName);
		assert(dca1.length == expectedLength, dca1.length.to!string);

		auto dir = buildPath(tempDir(), "filescanner_serializer_test");
		mkdirRecurse(dir);
		auto file = buildPath(dir, randomUUID().toString);
		scope (exit)
		{
			remove(file);
		}

		file.serializeDataClassArrayFile(dca1);
		//file.writeJSON(test_json_v2);

		auto jsonstring = file.readText;
		//writeln(jsonstring);
		auto json = jsonstring.parseJSON;

		auto jsonstring0 = expectedJsonFile.readText;
		auto json0 = jsonstring0.parseJSON;
		void normalizeSingleFileSpecShape(ref typeof(json) value)
		{
			auto records = value.object["dataArray"].array;
			foreach (ref record; records)
			{
				if ("fileSpecs" in record.object || !("fileName" in record.object))
					continue;
				JSONValue[string] fileSpecObject;
				fileSpecObject["fileName"] = record.object["fileName"];
				if ("timeLastModified" in record.object)
					fileSpecObject["timeLastModified"] =
						record.object["timeLastModified"];
				auto fileSpec = JSONValue(fileSpecObject);
				record.object["fileSpecs"] = JSONValue([fileSpec]);
				record.object.remove("fileName");
				record.object.remove("timeLastModified");
			}
			value.object["dataArray"] = JSONValue(records);
		}
		normalizeSingleFileSpecShape(json);
		normalizeSingleFileSpecShape(json0);

		// Tool versions are environment-dependent and are not part of the
		// serialized data contract covered by these fixtures.
		json.object.remove("fileUtilityVersion");
		json.object.remove("mediaInfoVersion");
		json0.object.remove("fileUtilityVersion");
		json0.object.remove("mediaInfoVersion");
		assert(json.object["dataVersion"].integer == DATA_CLASS_VERSION5);
		json.object.remove("dataVersion");
		json0.object.remove("dataVersion");
		assert(json == json0, "Parsed JSON does not match expected JSON.\nGot:\n" ~ json.toString ~ "\nExpected:\n" ~ json0
				.toString);
	}
}

@("(de)serializeDataClassArrayFile 1 - standard fields")
unittest
{
	testSerializeDataClassArrayFile(test_json_v2, 3, json_file_v2);
}

@("(de)serializeDataClassArrayFile 2 - archive serialization")
unittest
{
	import std.file : exists, remove, tempDir;
	import std.path : buildPath;
	import std.uuid : randomUUID;

	const auto fileName = buildPath(tempDir(), "archive-json-v5-"
		~ randomUUID().toString() ~ ".json");
	scope (exit)
		if (exists(fileName))
			remove(fileName);
	fileName.serializeDataClassArrayFile(
		deserializeDataClassJsonString(test_json_v2_archive));
	auto loaded = deserializeDataClassJsonWrapperFile(fileName);
	assert(loaded.dataVersion == DATA_CLASS_VERSION5);
	bool foundArchive;
	bool foundMember;
	string paths;
	foreach (blob; loaded.dataArray)
		foreach (spec; blob.fileSpecs)
		{
			paths ~= "[" ~ spec.fileName ~ "]";
			foundArchive = foundArchive || spec.fileName == "test.rar";
			foundMember = foundMember || spec.fileName == "test.rar!/urtzel.bin";
		}
	assert(foundArchive, paths);
	assert(foundMember, paths);
}

@("(de)serializeDataClassArrayFile 3 - torrentInfo serialization")
unittest
{
	testSerializeDataClassArrayFile(test_json_v2_torrent, 1, json_file_v2_torrent);
}
