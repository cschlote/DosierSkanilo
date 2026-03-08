/** Data class for a unique binary blob with multiple names and MediaInfo
 *
 * All scanned information must be stored somewhere. The NamedBinaryBlob provides
 * a container object for this purpose, so each file and all its scanned properties
 * is represented by an object.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, Released under CC-BY-NC-SA 4.0 license, 2018
 * License: CC-NC-BY 4.0
 */
module dosierskanilo.namedbinaryblob;

import std.array;
import std.algorithm;
import std.base64 : Base64;
import std.datetime.timezone : TimeZone;
import std.datetime.systime : SysTime;
import std.exception;
import std.conv : to;
import std.file : exists, readText, tempDir, getSize, getTimes, mkdirRecurse, rmdirRecurse;
import std.parallelism : Task, task;
import std.path : baseName, buildPath;
import std.process : thisProcessID, thisThreadID;
import std.stdio : writeln, writefln;
import std.string : format, empty;

import jsonizer;

import dosierskanilo.mediainfosig;
import dosierskanilo.digests;
import dosierskanilo.torrentinfo;

import dosierarkivo.baseclass;

import commandline;
import logging;

enum int DATA_CLASS_VERSION1 = 1; ///< Current version of the NamedBinaryBlob structure, v1
enum int DATA_CLASS_VERSION2 = 2; ///< Current version of the NamedBinaryBlob structure, v2
enum int DATA_CLASS_VERSION3 = 3; ///< Current version of the NamedBinaryBlob structure, v3

/** Wrapper class to serialize an array of NamedBinaryBlob objects
 *
 * This class is used to wrap an array of NamedBinaryBlob objects for serialization.
 * It also contains a version number to handle future changes in the data structure.
 */
struct NamedBinaryBlobWrapper
{
	/* Add code needed for JSON serialization */
	mixin JsonizeMe;

	/* public serialized members */
	@jsonize
	{
		ulong dataVersion; ///< version of the data structure
		NamedBinaryBlob[] dataArray; ///< Array of NamedBinaryBlob objects
	}

	/** constructor with parameters
	 *
	 * Params:
	 *   dataversion = version of the data structure
	 *   dataarray = Array of NamedBinaryBlob objects
	 */
	@jsonize this(ulong dataversion, NamedBinaryBlob[] dataarray)
	{
		dataVersion = dataversion;
		dataArray = dataarray;
	}
}

@("struct NamedBinaryBlobWrapper")
unittest
{
	auto mis0 = new NamedBinaryBlob();
	auto mis1 = new NamedBinaryBlob("file1", 1234, SysTime(1_234_567));
	auto mis2 = new NamedBinaryBlob(["file1", "file2"], 1234, SysTime(1_234_567));
	auto mis3 = new NamedBinaryBlob([
		new FileSpec("file8", SysTime(1_234_567)),
		new FileSpec("file9", SysTime(2_234_567))
	], 1234);
	auto wrap = NamedBinaryBlobWrapper(DATA_CLASS_VERSION3, [
		mis0, mis1, mis2, mis3
	]);
	assert(wrap.dataVersion == DATA_CLASS_VERSION3);
	assert(wrap.dataArray.length == 4);
}

/** Simple struct to store the checksums of a file
 *
 * This struct encapsulates the checksums of a file in base64 encoding.
 */
struct CheckSums
{
	/* Add code needed for JSON serialization */
	mixin JsonizeMe;

	/* public serialized members */
	@jsonize
	{
		string md5sum_b64; ///< base64 of md5 hash
		string sha1sum_b64; ///< base 64 of sha1 hash
		string xxh64sum_b64; ///< base 64 of sha1 hash
	}

	/** the file md5sum as a property */
	ubyte[] get_md5sum() const @property pure @safe
	{
		return (md5sum_b64 is null) ? null : Base64.decode(md5sum_b64);
	}

	/** setter - the file md5sum as a property */
	void set_md5sum(ubyte[] data) @property @safe
	{
		md5sum_b64 = (data is null) ? null : Base64.encode(data);
	}

	/** getter - the file md5sum as a property */
	ubyte[] get_sha1sum() const @property pure @safe
	{
		return (sha1sum_b64 is null) ? null : Base64.decode(sha1sum_b64);
	}

	/** setter - the file md5sum as a property */
	void set_sha1sum(ubyte[] data) @property @safe
	{
		sha1sum_b64 = (data is null) ? null : Base64.encode(data);
	}

	/** getter - the file md5sum as a property */
	ubyte[] get_xxh64() const @property pure @safe
	{
		return (xxh64sum_b64 is null) ? null : Base64.decode(xxh64sum_b64);
	}

	/** setter - the file md5sum as a property */
	void set_xxh64(ubyte[] data) @property @safe
	{
		xxh64sum_b64 = (data is null) ? null : Base64.encode(data);
	}

	/** Check if all three digests are present */
	bool hasDigests() @safe pure const
	{
		return !this.md5sum_b64.empty && !this.sha1sum_b64.empty && !this.xxh64sum_b64.empty;
	}

	/** equality operator
	*/
	bool opEquals(const CheckSums other) const @safe
	{
		return this.hasDigests && other.hasDigests &&
			this.md5sum_b64 == other.md5sum_b64 &&
			this.sha1sum_b64 == other.sha1sum_b64 &&
			this.xxh64sum_b64 == other.xxh64sum_b64;
	}
}

@("struct CheckSums")
unittest
{
	CheckSums sums;
	ubyte[] testdata = [1, 2, 3, 4, 5, 6, 7];

	sums.set_md5sum(testdata);
	assert(sums.get_md5sum == testdata, "Data Mismatch");
	assert(!sums.hasDigests, "Check failed.");

	sums.set_sha1sum(testdata);
	assert(sums.get_sha1sum == testdata, "Data Mismatch");
	assert(!sums.hasDigests, "Check failed.");

	sums.set_xxh64(testdata);
	assert(sums.get_xxh64 == testdata, "Data Mismatch");
	assert(sums.hasDigests, "Check failed.");
}

/* ----------------------------------------------------------------------------- */

/** Each binary blob can have multiple filenames and times */
class FileSpec
{
	/* Add code needed for JSON serialization */
	mixin JsonizeMe;

	@jsonize(JsonizeIn.opt, JsonizeOut.opt)
	{
		string fileName;
		string timeLastModified;
	}

	this()
	{
		fileName = "";
		timeLastModified = "";
	}

	this(string fn, string modtime) @safe
	{
		fileName = fn;
		timeLastModified = modtime;
	}

	import std.datetime : SysTime;
	import core.stdcpp.array;

	this(string fn, SysTime modtime)
	{
		fileName = fn;
		timeLastModified = modtime.toISOExtString;
	}

	int opCmp(FileSpec rhs) const pure
	{
		if (this.fileName > rhs.fileName)
			return 1;
		else if (this.fileName < rhs.fileName)
			return -1;
		else
			return 0;
	}

	override string toString() const pure
	{
		return format("FileSpec('%s', %s)", fileName, timeLastModified);
	}

	// int opEquals(FileSpec rhs) const pure
	// {
	// 	return this.fileName == rhs.fileName &&
	// 		this.timeLastModified == rhs.timeLastModified;
	// }

	import std.typecons : Nullable;

	private Nullable!bool fileExists; ///< Helper field, not serialized

	/** Check if the file exists on disk
	 *
	 * Returns: true, if the file exists on disk, false otherwise
	 * Note: The result is cached in the fileExists field to avoid multiple disk accesses for the same file.
	 */
	bool exists() @safe
	{
		import std.file : exists;

		if (this.fileExists.isNull)
		{
			this.fileExists = this.fileName.exists;
		}
		return this.fileExists.get;
	}
}

@("class FileSpec")
unittest
{
	auto ts = SysTime(1_234_567).toISOExtString;

	auto fs0 = new FileSpec();
	assert(fs0.toString == `FileSpec('', )`, fs0.toString);

	auto fs1 = new FileSpec("test/dummy-text-file.txt", SysTime(1_234_567));
	assert(fs1.toString == format("FileSpec('%s', %s)", "test/dummy-text-file.txt", ts), fs1.toString);
	assert(fs1.exists, "File must exist");

	auto fs2 = new FileSpec("test/non-existing-file.txt", SysTime(1_234_567));
	assert(!fs2.exists, "File must not exist");

	assert(fs1.opCmp(fs2) < 0, "fs1 < fs2");
	assert(fs2.opCmp(fs1) > 0, "fs2 > fs1");
	assert(fs1.opCmp(fs1) == 0, "fs1 == fs1");
}

/* ----------------------------------------------------------------------------- */

/** Contents description of an archive file
 *
 * There are several known archive file formats (zip, tar, rar, 7z, ...). Each of
 * them can contain multiple files inside. We store the basic information
 * about each file inside the archive in this class.
 */
class ArchiveSpec
{
	/* Add code needed for JSON serialization */
	mixin JsonizeMe;

	/* public serialized members */
	@jsonize
	{
		string fileName;
		size_t fileSize;
		string timeLastModified;
		@jsonize(JsonizeIn.opt, JsonizeOut.opt)
		CheckSums checkSums;
	}

	this()
	{
		fileName = "";
		fileSize = 0;
		timeLastModified = "";
		checkSums = CheckSums();
	}

	this(string fn, size_t fsize, string modtime, CheckSums sums)
	{
		fileName = fn;
		fileSize = fsize;
		timeLastModified = modtime;
		checkSums = sums;
	}

	import std.datetime : SysTime;
	import core.stdcpp.array;
	import std.experimental.allocator.building_blocks.fallback_allocator;

	this(string fn, size_t fsize, SysTime modtime, CheckSums sums)
	{
		fileName = fn;
		fileSize = fsize;
		timeLastModified = modtime.toISOExtString;
		checkSums = sums;
	}

	int opCmp(ArchiveSpec rhs) const pure
	{
		if (this.fileName > rhs.fileName)
			return 1;
		else if (this.fileName < rhs.fileName)
			return -1;
		else
			return 0;
	}

	override string toString() const pure
	{
		return format("ArchiveSpec('%s', %d, '%s', %s)", fileName, fileSize, timeLastModified, checkSums);
	}
}

@("class ArchiveSpec")
unittest
{
	auto ts = SysTime(1_234_567).toISOExtString;

	auto as0 = new ArchiveSpec();
	auto asd0 = as0.toString;
	// writeln("AS0: ", asd0);
	assert(asd0 == `ArchiveSpec('', 0, '', const(CheckSums)("", "", ""))`, as0.toString);

	auto as1 = new ArchiveSpec("test/dummy-text-file.txt", 1_234_567, SysTime(1_234_567), CheckSums());
	auto asd1 = as1.toString;
	// writeln("AS1: ", asd1);
	assert(
		asd1 == format("ArchiveSpec('%s', %d, '%s', %s)", "test/dummy-text-file.txt", 1_234_567, ts,
				const(CheckSums)()), as1
			.toString);

	assert(as1.opCmp(as0) > 0, "as1 > as0");
	assert(as0.opCmp(as1) < 0, "as0 < as1");
	assert(as1.opCmp(as1) == 0, "as1 == as1");
}

/* ----------------------------------------------------------------------------- */

/// Helper variables of the class
mixin template payloadHelpers()
{
	//bool invalidated; ///< Set, when file entry is marked for removal
	bool isBlobOrphaned() ///< Set, when there is no file entry on disk for this blob
	{
		import std.algorithm : any;

		bool rc = false;
		if (fileSpecs.length == 0)
			rc = true;
		else
		{
			rc = fileSpecs.any!(a => !a.exists());
		}
		return rc;
	}

	Task!(updateDigests, NamedBinaryBlob, shared(bool)*, ProgressCallBack*)* task_hashme; ///< Pointer to hashing job
	Task!(updateFileType, NamedBinaryBlob)* task_filetype; /// Query filetype with 'file' utility
	Task!(updateMediaInfo, NamedBinaryBlob)* task_mediasig; ///< Pointer to mediasig job
	Task!(updateArchives, NamedBinaryBlob)* task_archiveScan; ///< Pointer to archive scan job
	Task!(updateTorrentInfo, NamedBinaryBlob)* task_torrentscan; ///< Pointer to torrent scan job
}
/// Mandatory variables of the class describing a binary blob
mixin template payloadMandatory()
{
	CheckSums checkSums; ///< Multiple checksums of the file
	size_t fileSize; ///< file size
}
/// Optional variables of the class
mixin template payloadOptional()
{
	/** Filename fields
	 *
	 * We support either a single filename (fileName) or multiple filenames
	 * (fileNames) for entries that represent multiple files (like multi-part
	 * archives or multi-track media files).
	 */
	string fileName; ///< absolute filename  AND
	string timeLastModified; ///< Time of last modification OR
	@jsonize(JsonizeIn.opt, JsonizeOut.no) string[] fileNames; ///< set of absolute filenames and time (for multiple entries) OR
	FileSpec[] fileSpecs; /// v3: combined entry

	string fileType; /// Output of 'file' CLI tool.
	MediaInfoSig mediaInfoSig; ///< Parsed media info signature
	ArchiveSpec[] archiveSpecs; /// Contents of an archive
	TorrentInfo torrentInfo; /// Extracted torrent information

	// Legacy fields, kept for backward compatibility, but not serialized anymore
	// Data is dropped during serialization
	@jsonize(JsonizeIn.opt, JsonizeOut.no)
	 // deprecated  // causes tons of messages...
	{
		string[] mediaInfo; ///< A media signature constructed with libmediainfo or NULL for no media file
		string md5sum_b64; ///< base64 of md5 hash
		string sha1sum_b64; ///< base 64 of sha1 hash
		string xxh64sum_b64; ///< base 64 of sha1 hash
	}
}

/** Simple class to store the basic file properties
 *
 * Encapsulate the payload into this class. Also some property functions
 * allow to store the binary data as base64 strings instead of ubyte arrays.
 * This saves a lot of space in the resulting storage files (strings are much
 * shorter then typical array representations).
 */
class NamedBinaryBlob
{
	/* Add code needed for JSON serialization */
	mixin JsonizeMe;

	/* ------------------------------------------------------------------- */
	/* Some helper vars not serialized */
	// private:
	mixin payloadHelpers;

	// public:
	/* public serialized members */
	@jsonize
	{
		mixin payloadMandatory;
		@jsonize(Jsonize.opt)
		{
			mixin payloadOptional;
		}
	}
	/* ------------------------------------------------------------------- */

	/* ------------------------------------------------------------------- */

	/** default constructor */
	this()
	{
		// Internal fields
		// invalidated = false;
		// isFileMissing = false;
		task_hashme = null;
		task_mediasig = null;

		// Unique binary blob parameters
		fileSpecs = [];
		fileSize = 0;
		checkSums = CheckSums();

		// Optional values with special usage
		fileNames = null; // OBSOLETE
		fileName = null; // Used to replace array by single string
		fileType = null; // Clear file util output
		timeLastModified = ""; // Used to replace array by single string
		mediaInfo = null; // More humand readable format
		mediaInfoSig = null; // MediaInfo as JSON fields
	}

	/** constructor with parameters for single file entry
	 *
	 * Params:
	 *   specs = array of FileSpec entries
	 *   size = file size
	 */
	this(FileSpec[] specs, size_t size)
	{
		this();
		fileSpecs ~= specs;
		fileSize = size;
	}
	/** constructor with parameters for single file entry
	 *
	 * Params:
	 *   name = absolute filename
	 *   size = file size
	 *   modificationTime = time of last modification
	 */
	this(string name, size_t size, SysTime modificationTime)
	{
		this();
		auto fileSpec = new FileSpec(name, modificationTime.toISOExtString);
		fileSpecs ~= fileSpec;
		fileSize = size;
	}

	/** constructor with parameters for single file entry
	 *
	 * Params:
	 *   names = absolute filenames
	 *   size = file size
	 *   modificationTime = time of last modification
	 */
	this(string[] names, size_t size, SysTime modificationTime)
	{
		this();
		foreach (fn; names)
			fileSpecs ~= new FileSpec(fn, modificationTime.toISOExtString);
		fileSize = size;
	}

	/** constructor with parameters for single file entry
	 *
	 * Params:
	 *   name = absolute filename
	 *   size = file size
	 *   modificationTime = time of last modification
	 *   sums = checksums
	 *   mt = media info or null
	 */
	this(string name, size_t size, SysTime modificationTime, CheckSums sums, MediaInfoSig mt = null)
	{
		this(name, size, modificationTime);
		checkSums = sums;
		mediaInfoSig = mt;
	}

	/** constructor with parameters for entry with several file entries
	 *
	 * Params:
	 *   names = absolute filenames
	 *   size = file size
	 *   modificationTime = time of last modification
	 *   sums = checksums
	 *   mt = media info or null
	 */
	this(string[] names, size_t size, SysTime modificationTime, CheckSums sums, MediaInfoSig mt = null)
	{
		this(names, size, modificationTime);
		//fileName = null;
		fileNames = names;
		fileSize = size;
		timeLastModified = modificationTime.toISOExtString();
		checkSums = sums;
		mediaInfoSig = mt;
	}

	/** copy constructor
	*
	* Params:
	*   other = Init object
	*/
	this(NamedBinaryBlob other)
	{
		this();
		fileSpecs = other.fileSpecs;
		fileNames = other.fileNames;
		fileSize = other.fileSize;
		timeLastModified = other.timeLastModified;
		checkSums = other.checkSums;
		mediaInfoSig = other.mediaInfoSig;
	}

	/* ------------------------------------------------------------------- */

	/** create a string from the object contents */
	override string toString()
	{
		//assert(fileNames.length > 0, "NamedBinaryBlob entry has no filenames!");
		auto filename = this.getFirstFileName;
		auto mtime = this.getFirstFileModDate;

		return format("NamedBinaryBlob('%s', %d, %s, %s, %s)",
			baseName(filename), fileSize, mtime, this.checkSums, this.mediaInfoSig);
	}

	/* ------------------------------------------------------------------- */

	/** equality operator
	 *
	 * We assume rquality, when size and checksums are equal. The filenames
	 * or media info are not relevant for equality. They are just metadata.
	 *
	 * We also check for full checksums. If not available, we can't match.
	 *
	 * Params:
	 *   other = other NamedBinaryBlob object to compare with
	 * Returns: true, if both objects are equal
	*/
	bool opEquals(const NamedBinaryBlob other) const @safe
	{
		return this.fileSize == other.fileSize &&
			this.checkSums == other.checkSums;
	}

	/* ------------------------------------------------------------------- */

	NamedBinaryBlob dup()
	{
		auto dc = new NamedBinaryBlob(this);
		if (dc.mediaInfoSig !is null)
			dc.mediaInfoSig = dc.mediaInfoSig.dup;
		return dc;
	}

	/* ------------------------------------------------------------------- */

	/** Get the first modification timestamp from sorted file entries.
	 *
	 * Returns: first file modification time, or "" for an empty set.
	 */
	string getFirstFileModDate() pure
	{
		import std.algorithm.sorting : sort;

		auto rs = this.fileSpecs.length ? this.fileSpecs.sort.front.timeLastModified : "";
		return rs;
	}

	/** Get the first filename from sorted file entries.
	 *
	 * Returns: first filename, or "" for an empty set.
	 */
	string getFirstFileName() pure
	{
		import std.algorithm.sorting : sort;

		auto rs = this.fileSpecs.length ? this.fileSpecs.sort.front.fileName : "";
		return rs;
	}

	/* ------------------------------------------------------------------- */

	/** Get all file entries that still exist on disk.
	 *
	 * Returns: existing `FileSpec` entries, or an empty array if none exist.
	 */
	FileSpec[] getExistingFiles()
	{
		import std.algorithm.sorting : sort;

		FileSpec[] rs = null;
		if (fileSpecs.length)
		{
			import std.file : exists;

			rs = fileSpecs.filter!(a => a.exists).array;
		}
		return rs;
	}

	/** Get the first existing filename from sorted file entries.
	 *
	 * Returns: first existing filename, or "" for an empty set.
	 */
	string getFirstExistingFileName()
	{
		import std.algorithm.sorting : sort;

		auto rs = this.getExistingFiles.length ? this.fileSpecs.sort.front.fileName : "";
		return rs;
	}

	/** Find a filename in a set of fileSpecs
	*/
	bool hasFileName(string filename) @safe
	{
		import std.algorithm.searching : find;

		bool rc = false;
		alias matcher = (a, b) => a.fileName == b;
		auto found = this.fileSpecs.find!(matcher, FileSpec[], string)(filename);
		if (found.length)
			rc = true;
		return rc;
	}

	/** Get a FileSpec by its filename
	*/
	FileSpec getFileSpec(string filename) @safe
	{
		import std.algorithm.searching : find;

		alias matcher = (a, b) => a.fileName == b;
		auto found = this.fileSpecs.find!(matcher, FileSpec[], string)(filename);
		if (found.length)
			return found[0];
		else
			return null;
	}

	/** Add a FileSpec by its filename
	 *
	 * Params:
	 *   filename = filename to add
	 *   timeLastModified = modification time
	 * Returns:
	 *   newly created FileSpec
	 */
	FileSpec addFileSpec(string filename, string timeLastModified) @safe
	{
		enforce(!this.hasFileName(filename),
			"FileSpec with filename '%s' already exists.".format(filename));

		auto fs = new FileSpec(filename, timeLastModified);
		this.fileSpecs ~= fs;
		return fs;
	}

	/** Delete a FileSpec by its filename
	 *
	 * Params:
	 *   filename = filename to delete
	 * Returns: the deleted FileSpec, or null if not found
	 */
	FileSpec deleteFileSpec(string filename) @safe
	{
		import std.algorithm.searching : find;
		import std.algorithm : remove;

		alias matcher = (a, b) => a.fileName == b;
		auto found = this.fileSpecs.find!(matcher, FileSpec[], string)(filename);
		if (!found.empty)
		{
			auto fs = found[0];
			this.fileSpecs = this.fileSpecs.filter!(a => a.fileName != filename).array;
			return fs;
		}
		else
			return null;
	}

}

@("class MediaInfoSig")
unittest
{
	auto ts = SysTime(1_234_567).toISOExtString;
	auto ts2 = SysTime(2_345_678).toISOExtString;

	auto mis0 = new NamedBinaryBlob();
	assert(mis0.toString == `NamedBinaryBlob('', 0, , CheckSums("", "", ""), null)`, mis0.toString);
	auto mis1 = new NamedBinaryBlob("file1", 1234, SysTime(1_234_567));
	assert(mis1.toString == format("NamedBinaryBlob('file1', 1234, %s, CheckSums(\"\", \"\", \"\"), null)", ts),
		mis1.toString);
	auto mis2 = new NamedBinaryBlob(["file1", "file2"], 1234, SysTime(1_234_567));
	assert(mis2.toString == format("NamedBinaryBlob('file1', 1234, %s, CheckSums(\"\", \"\", \"\"), null)", ts),
		mis2.toString);
	auto mis3 = new NamedBinaryBlob(["file1", "file2"], 1234, SysTime(1_234_567), CheckSums());
	assert(mis3.toString == format("NamedBinaryBlob('file1', 1234, %s, CheckSums(\"\", \"\", \"\"), null)", ts),
		mis3.toString);
	auto mis4 = new NamedBinaryBlob(["file1", "file2"], 1234, SysTime(1_234_567), CheckSums("a", "b", "c"), new MediaInfoSig());
	assert(
		mis4.toString == format("NamedBinaryBlob('file1', 1234, %s, CheckSums(\"a\", \"b\", \"c\"), MediaInfoSig())", ts),
		mis4.toString);
	auto mis5 = new NamedBinaryBlob("file1", 1234, SysTime(1_234_567), CheckSums());
	assert(mis5.toString == format("NamedBinaryBlob('file1', 1234, %s, CheckSums(\"\", \"\", \"\"), null)", ts),
		mis5.toString);
	auto mis6 = new NamedBinaryBlob("file1", 1234, SysTime(1_234_567), CheckSums(), new MediaInfoSig());
	assert(
		mis6.toString == format("NamedBinaryBlob('file1', 1234, %s, CheckSums(\"\", \"\", \"\"), MediaInfoSig())", ts),
		mis6.toString);

	auto mis10 = new NamedBinaryBlob(mis4);
	assert(mis10 == mis4, "Same contents");
	assert(&mis10 != &mis4, "Same objects?");

	auto mis11 = mis4.dup;
	assert(mis11 == mis4, "Same contents");
	assert(&mis11 != &mis4, "Same objects?");

	auto mis12 = new NamedBinaryBlob(["file2", "file8", "file1"], 1234, SysTime(1_234_567));
	assert(mis12.getFirstFileName == "file1");
	assert(mis12.toString == format("NamedBinaryBlob('file1', 1234, %s, CheckSums(\"\", \"\", \"\"), null)", ts),
		mis12.toString);

	assert(mis12.hasFileName("file8"));
	assert(!mis12.hasFileName("file9"));
	assert(mis12.getFileSpec("file8") !is null);
	assert(mis12.getFileSpec("file9") is null);

	auto fs = mis12.addFileSpec("file9", SysTime(2_345_678).toISOExtString);
	assert(fs !is null);
	assert(mis12.hasFileName("file9"));
	fs = mis12.deleteFileSpec("file8");
	assert(fs !is null);
	fs = mis12.deleteFileSpec("file8");
	assert(fs is null);
	assert(!mis12.hasFileName("file8"));
	assert(mis12.fileSpecs.length == 3);
	assert(mis12.fileSpecs[0].fileName == "file1");
	assert(mis12.fileSpecs[1].fileName == "file2");
	assert(mis12.fileSpecs[2].fileName == "file9");
	assert(mis12.fileSpecs[0].timeLastModified == ts);
	assert(mis12.fileSpecs[1].timeLastModified == ts);
	assert(mis12.fileSpecs[2].timeLastModified == ts2);

	auto mis13 = new NamedBinaryBlob([
		"file2", "file8", "file1",
		"test/dummy-audio-file.mp3", "test/dummy-text-file.txt"
	], 1234, SysTime(1_234_567));
	assert(mis13.fileSpecs.length == 5);
	auto en = mis13.getExistingFiles();
	assert(en.length == 2);

}

/* ----------------------------------------------------------------------- */

/* ----------------------------------------------------------------------- */

/** Sort an array of NamedBinaryBlob objects by their filenames
 *
 * Params:
 *   dataArray = Array of NamedBinaryBlob objects to sort
 * Returns: Sorted array of NamedBinaryBlob objects
 */
NamedBinaryBlob[] sortDataClassArrayByFileName(NamedBinaryBlob[] dataArray)
{
	import std.algorithm.sorting : sort;
	import std.algorithm.mutation : SwapStrategy;

	alias myCmp = (a, b) {
		assert(a.fileSpecs.length > 0,
			"NamedBinaryBlob entry a has no filenames!");
		assert(b.fileSpecs.length > 0,
			"NamedBinaryBlob entry b has no filenames!");

		return a.getFirstFileName < b.getFirstFileName;

	};
	auto sortedData_rng = sort!(myCmp, SwapStrategy.unstable,
		typeof(dataArray))(dataArray);

	import std.algorithm.mutation : copy;

	NamedBinaryBlob[] sortedData;
	sortedData.length = dataArray.length;
	copy(sortedData_rng, sortedData);

	return sortedData;
}

@("sortDataClassArrayByFileName")
unittest
{
	auto mis0 = new NamedBinaryBlob("file8", 1234, SysTime(1_234_567));
	auto mis1 = new NamedBinaryBlob("file1", 2345, SysTime(1_234_567));
	auto mis2 = new NamedBinaryBlob(["file2", "file3"], 3456, SysTime(1_234_567));
	auto sl = sortDataClassArrayByFileName([mis0, mis1, mis2]);
	assert(sl.length == 3);
	assert(sl[0].getFirstFileName == "file1");
	assert(sl[1].getFirstFileName == "file2");
	assert(sl[2].getFirstFileName == "file8");
}

/** Remove duplicate entries from NamedBinaryBlob array by their filenames
 *
 * Params:
 *   dataArray = Array of NamedBinaryBlob objects to process
 * Returns: Array of NamedBinaryBlob objects with unique filenames
 */
NamedBinaryBlob[] uniqDataClassArrayByFileName(NamedBinaryBlob[] dataArray)
{
	import std.algorithm.iteration : uniq;
	import std.algorithm.mutation : copy;

	NamedBinaryBlob[] uniqSortedData;
	uniqSortedData.length = dataArray.length;
	enum myEqual = "a.getFirstFileName == b.getFirstFileName";
	auto uniqSortedData_rng = uniq!(myEqual, typeof(dataArray))(
		dataArray);
	const auto remainingRng = copy(uniqSortedData_rng, uniqSortedData);
	uniqSortedData.length -= remainingRng.length;
	return uniqSortedData;
}

@("uniqDataClassArrayByFileName")
unittest
{
	auto mis0 = new NamedBinaryBlob("file1", 1234, SysTime(1_234_567));
	auto mis1 = new NamedBinaryBlob("file1", 2345, SysTime(1_234_567));
	auto mis2 = new NamedBinaryBlob(["file2", "file3"], 3456, SysTime(1_234_567));
	auto sl = uniqDataClassArrayByFileName([mis0, mis1, mis2]);
	assert(sl.length == 2);
	assert(sl[0].getFirstFileName == "file1");
	assert(sl[0].fileSize == 1234);
	assert(sl[1].getFirstFileName == "file2");
	assert(sl[1].fileSize == 3456);
}

version (unittest)
{
	auto test_json_v0 = import("./test/json_file_v0.json");
	auto test_json_v1 = import("./test/json_file_v1.json");
	auto test_json_v2 = import("./test/json_file_v2.json");
}

/** Fixup legacy fields in NamedBinaryBlob array for deserialization
 *
 * Params:
 *   dataArray = Array of NamedBinaryBlob objects to process
 * Returns: Updated array of NamedBinaryBlob objects
 */
NamedBinaryBlob[] fixupDataClassArrayIn(NamedBinaryBlob[] dataArray)
{
	// -- Fixup legacy fields ---------------------------
	foreach (ref obj; dataArray)
	{
		// -- Fixup legacy filename field ---------------------------
		/* The same data blob may have been stored with either a single
		 * filename (fileName) or multiple filenames (fileNames).
		 * We convert all entries to use the fileNames array.
		 */
		if (obj.fileName.empty == false)
		{
			obj.fileSpecs ~= new FileSpec(obj.fileName, obj.timeLastModified);
			obj.fileName = null;
			obj.timeLastModified = null;
		}
		// -- Fixup legacy 2 - filenames and dates must be together --
		if (obj.fileNames.empty == false)
		{
			foreach (fn; obj.fileNames)
				obj.fileSpecs ~= new FileSpec(fn, obj.timeLastModified);
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
					if (v.index == -1)
						v.index = 0;
				foreach (v; videoStreams)
					if (v.index == -1)
						v.index = 0;
				foreach (v; audioStreams)
					if (v.index == -1)
						v.index = 0;
				foreach (v; textStreams)
					if (v.index == -1)
						v.index = 0;
			}
		}
		//-- filter empty mediaInfoSig ---------------------------
		if (obj.mediaInfoSig !is null && obj.mediaInfoSig.empty)
		{
			obj.mediaInfoSig = null;
		}

		// -- Fixup broken torrent entries ---------------------------
		if ((obj.torrentInfo !is null) && (obj.torrentInfo.infoHashHex.empty))
		{
			obj.torrentInfo = null;
		}
	}

	return dataArray;
}

/** Fixup NamedBinaryBlob array before serialization
 *
 * Params:
 *   dataArray = Array of NamedBinaryBlob objects to process
 * Returns: Updated array of NamedBinaryBlob objects
 */
NamedBinaryBlob[] fixupDataClassArrayOut(NamedBinaryBlob[] dataArray)
{
	// -- Fixup legacy fields ---------------------------
	foreach (ref obj; dataArray)
	{
		// -- Clear legacy filename field ---------------------------
		if (obj.fileSpecs.length > 1)
		{
			obj.fileName = "";
			obj.timeLastModified = "";
		}
		// -- We have just a single name, setup the single filename --
		else
		{
			obj.fileName = obj.fileSpecs[0].fileName;
			obj.timeLastModified = obj.fileSpecs[0].timeLastModified;
			obj.fileSpecs = [];
		}
		assert(obj.fileNames.length == 0, "fileNames are of service.");

		// -- Clear legacy digest fields ---------------------------
		obj.md5sum_b64 = null;
		obj.sha1sum_b64 = null;
		obj.xxh64sum_b64 = null;

		// -- Clear legacy mediaInfo field ---------------------------
		obj.mediaInfo = null;

		if (obj.mediaInfoSig !is null && obj.mediaInfoSig.empty)
		{
			obj.mediaInfoSig = null;
		}

		// -- Fixup broken torrent entries ---------------------------
		if ((obj.torrentInfo !is null) && (obj.torrentInfo.empty))
		{
			obj.torrentInfo = null;
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

/** Deserialize a JSON file and return NamedBinaryBlob[] array
 *
 * Params:
 *   serializedData = JSON string with serialized NamedBinaryBlob data
 * Returns:
 *   array of deserialized NamedBinaryBlob objects
 */
NamedBinaryBlob[] deserializeDataClassJsonString(const string serializedData)
{
	NamedBinaryBlobWrapper wrapper;

	NamedBinaryBlob[] deserializedData;
	ulong deserializedObjectsLength;

	// Check for new JSON object format
	if (serializedData[0] != '[')
	{
		logLineVerbose("  Reading into NamedBinaryBlobWrapper object (new format)...");
		wrapper = fromJSONString!(NamedBinaryBlobWrapper)(serializedData);
		import std.exception : enforce;
		import std.conv : to;

		if (wrapper.dataVersion == DATA_CLASS_VERSION1)
		{
			wrapper.dataArray = fixupDataClassArrayIn(wrapper.dataArray);
			wrapper.dataVersion = DATA_CLASS_VERSION2;
		}

		enforce(wrapper.dataVersion == DATA_CLASS_VERSION2,
			"Data version mismatch, expected " ~ to!string(
				DATA_CLASS_VERSION2) ~ ", got " ~ to!string(wrapper.dataVersion));
	}
	// Check for old plain array JSON
	else if (serializedData[0] == '[')
	{
		logLineVerbose("  Reading directly into NamedBinaryBlob[] array (legacy format)...");
		wrapper.dataArray = fromJSONString!(NamedBinaryBlob[])(serializedData);
		wrapper.dataArray = fixupDataClassArrayIn(wrapper.dataArray);
		wrapper.dataVersion = DATA_CLASS_VERSION2;
	}
	// Shouldn't happen
	else
		assert(false, "Unknow JSON format?");

	deserializedData = wrapper.dataArray;

	deserializedObjectsLength = deserializedData.length;
	logFLineVerbose("  got %d entries in array after deserialization() of archive data.", deserializedObjectsLength);

	logFLineVerbose("  fixup legacy fields in deserialized array...");
	deserializedData = fixupDataClassArrayIn(deserializedData);
	logFLineVerbose("  sort and uniq deserialized array by their filenames (use a range)");
	auto sortedDeserializedData_rng = sortDataClassArrayByFileName(deserializedData);
	auto uniqSortedDeserializedData = uniqDataClassArrayByFileName(sortedDeserializedData_rng);

	logFLineVerbose("  got %d entries in array after uniq()", uniqSortedDeserializedData.length);

	return uniqSortedDeserializedData;
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

	assert(dca0 == dca1);
	assert(dca0 == dca2);
}

/** Deserialize a JSON file and return NamedBinaryBlob[] array
 *
 * Params:
 *   fileName = the name of JSON file to read.
 * Returns:
 *   array of deserialized NamedBinaryBlob objects, or empty array when file is missing
 */
NamedBinaryBlob[] deserializeDataClassJsonFile(string fileName, bool verbose = false)
{
	logFLineVerbose("Read serialized data from JSON file %s", fileName);
	//enforce(exists(fileName), "File %s does not exist!".format(fileName));
	if (!exists(fileName))
		return [];

	logFLineVerbose("  reading file '%s' into the serializer archive container", fileName);
	const string serializedData = readText(fileName);

	return deserializeDataClassJsonString(serializedData);
}

@("deserializeDataClassJsonFile")
unittest
{
	auto dca = deserializeDataClassJsonFile("./test/json_file_notexisting.json");
	assert(dca.length == 0);

	auto dca0 = deserializeDataClassJsonFile("./test/json_file_v0.json");
	assert(dca0.length == 3);

	auto dca1 = deserializeDataClassJsonFile("./test/json_file_v1.json");
	assert(dca1.length == 3);

	auto dca2 = deserializeDataClassJsonFile("./test/json_file_v2.json");
	assert(dca2.length == 3);

	assert(dca0 == dca1);
	assert(dca0 == dca2);

	auto job0 = function() {
		auto dca2 = deserializeDataClassJsonFile("./test/json_file_v1_wrongversion.json");
	};
	assertThrown(job0(), "No bumm?");
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
	logFLineVerbose("Generate JSON data and write it to file %s", fileName);
	NamedBinaryBlobWrapper wrapper;
	wrapper.dataVersion = DATA_CLASS_VERSION2;

	logFLineVerbose("  sort and uniq serialized array by their filenames (use a range)");
	auto sortedDeserializedData_rng = sortDataClassArrayByFileName(dataArray);
	auto uniqSortedDeserializedData = uniqDataClassArrayByFileName(sortedDeserializedData_rng);
	wrapper.dataArray = uniqSortedDeserializedData;

	wrapper.dataArray = fixupDataClassArrayOut(wrapper.dataArray);
	writeJSON!(NamedBinaryBlobWrapper)(fileName, wrapper);
	wrapper.dataArray = fixupDataClassArrayIn(wrapper.dataArray);
}

@("serializeDataClassArrayFile")
unittest
{
	auto dca1 = deserializeDataClassJsonFile("./test/json_file_v2.json");
	assert(dca1.length == 3);

	import std.path : buildPath;
	import std.file : tempDir, mkdirRecurse, remove;
	import std.json : parseJSON;
	import std.uuid : randomUUID;

	auto dir = buildPath(tempDir(), "filescanner_serializer_test");
	mkdirRecurse(dir);
	auto file = buildPath(dir, randomUUID().toString);

	file.serializeDataClassArrayFile(dca1);
	//file.writeJSON(test_json_v1);
	auto jsonstring = file.readText;
	//writeln(jsonstring);
	auto json = jsonstring.parseJSON;

	remove(file);
}

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

		ubyte[] md, sha, xxh;
		calculatesDigests(gotCtrlC, obj.getFirstExistingFileName, &md, &sha, &xxh, progressCallBack);
		obj.checkSums.set_md5sum = md;
		obj.checkSums.set_sha1sum = sha;
		obj.checkSums.set_xxh64 = xxh;
	}
}

@("updateDigest")
unittest
{
	import std.stdio : File;

	string filename = "./test/dummy-audio-file.mp3";
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
		import std.algorithm.sorting : sort;
		import std.file : exists;

		if (obj.fileSize) // Empty files surely have no info at all....
		{
			// Find first existing file.
			auto filespecs = obj.getExistingFiles;
			foreach (spec; filespecs)
			{
				import dosierskanilo.fileutilsig : getFileType;

				obj.fileType = getFileType(spec.fileName);
				break;
			}
		}
	}
}

@("updateFileType")
unittest
{
	import std.stdio : File;

	string filename = "./test/dummy-audio-file.mp3";
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
 */
void updateMediaInfo(NamedBinaryBlob obj, bool rescan = false)
{
	if (obj.mediaInfoSig is null || rescan)
	{
		import std.algorithm.sorting : sort;
		import std.file : exists;

		if (obj.fileSize) // Empty files surely have no info at all....
		{
			auto filespecs = obj.fileSpecs.sort;
			foreach (spec; obj.getExistingFiles)
			{
				obj.mediaInfoSig = getMediaTypeSignature(spec.fileName);
				break;
			}
		}
	}
}

@("updateMediaInfo")
unittest
{
	import std.stdio : File;

	string filename = "./test/dummy-audio-file.mp3";
	auto fh = File(filename);
	auto dco = new NamedBinaryBlob(filename, fh.size, SysTime(4_237_892));
	updateMediaInfo(dco, true);
	assert(dco.mediaInfoSig, "No MediaInfo was set.");
}

/** Get the contents of an archive file
 *
 * This code is called for a unique binary blob. So the MediaInfo MUST be
 * identical.
 *
 * Params:
 *   obj = NamedBinaryBlob object to update
 *   rescan = force rescan even if info exists
 *   gotCtrlC = shared bool pointer to check for Ctrl-C interrupt
 *   progressCallBack = callback function to report progress
 */
void updateArchives(NamedBinaryBlob obj, bool rescan = false,
	shared(bool)* gotCtrlC = null,
	ProgressCallBack* progressCallBack = null)
{
	string getTmpDirPrefix() const
	{
		return buildPath(tempDir, "dosierskanilo-" ~ thisProcessID.to!string ~ "-" ~ thisThreadID
				.to!string);
	}

	if (obj.archiveSpecs is null || rescan)
	{
		import std.algorithm.sorting : sort;
		import std.file : exists;

		if (obj.fileSize) // Empty files surely have no info at all....
		{
			auto filespecs = obj.fileSpecs.sort;
			foreach (spec; obj.getExistingFiles)
			{
				auto archiveObj = fileArchive(spec.fileName);
				if (archiveObj)
				{
					logLineVerbose();
					logFLineVerbose("Found archive of type '%s'", archiveObj.fileType);
					logFLineVerbose("  with file '%s'", spec.fileName);
					logFLineVerbose("  with size %d", obj.fileSize);
					logFLineVerbose("  with 'file' type '%s'", obj.fileType);

					auto arcfiles = archiveObj.getEntries();
					logFLine("  with %d entries", arcfiles.length);
					if (progressCallBack !is null)
						progressCallBack.fp(0, arcfiles.length);

					foreach (idx, arcfile; arcfiles)
					{
						logFLineVerbose("\n  with archive file '%s'", arcfile);
						mkdirRecurse(getTmpDirPrefix);
						scope (success)
							if (getTmpDirPrefix.exists)
								rmdirRecurse(getTmpDirPrefix);

						auto destFile = buildPath(getTmpDirPrefix(), arcfile);
						auto exOk = archiveObj.extractEntry(arcfile, getTmpDirPrefix());

						enforce(destFile.exists, destFile);

						import dosierskanilo.digests;
						import std.stdio : File;

						ubyte[] md5sum_s, sha1sum_s, xxh64sum_s;
						calculatesDigests(gotCtrlC, destFile, &md5sum_s, &sha1sum_s, &xxh64sum_s, progressCallBack);
						if (progressCallBack !is null)
							progressCallBack.fp(idx, arcfiles.length);

						CheckSums sums = CheckSums();
						sums.set_md5sum = md5sum_s;
						sums.set_sha1sum = sha1sum_s;
						sums.set_xxh64 = xxh64sum_s;

						SysTime arcAccessTime;
						SysTime arcModTime;
						destFile.getTimes(arcAccessTime, arcModTime);
						auto arcModTimeStr = arcModTime.toISOExtString;

						auto arcFileSize = destFile.getSize;

						ArchiveSpec aspec = new ArchiveSpec(arcfile, arcFileSize, arcModTimeStr, sums);
						obj.archiveSpecs ~= aspec;
					}
					if (progressCallBack !is null)
						progressCallBack.fp(arcfiles.length, arcfiles.length);
					break;

				}
			}
		}
	}
}

@("updateArchives")
unittest
{
	import std.stdio;
	import std.file; // : exists, remove, write, mkdirRecurse, rmdirRecurse;
	import std.process;
	import std.conv : to;
	import std.string : format;
	import std.path : buildPath;

	string filename = "./test/dummy-audio-file.mp3";
	auto fh = File(filename);
	auto dco = new NamedBinaryBlob(filename, fh.size, SysTime(4_237_892));
	updateArchives(dco, true);
	assert(dco.archiveSpecs.length == 0);

	enum string fn = "updateTest.zip";
	void deleteTestArchive()
	{
		if (fn.exists)
			std.file.remove(fn);
	}

	void createTestArchive()
	{
		deleteTestArchive();
		auto rc = executeShell("zip -q \"%s\" test/*".format(fn));
		write(rc.output);
		assert(rc.status == 0, rc.output);
	}

	enum string fnMany = "updateTest-many.zip";
	enum string stagingDir = "test/updateArchives-many-entries";

	void deleteManyEntriesArchive()
	{
		if (fnMany.exists)
			std.file.remove(fnMany);
		if (stagingDir.exists)
			rmdirRecurse(stagingDir);
	}

	void createManyEntriesArchive(size_t entryCount)
	{
		deleteManyEntriesArchive();
		mkdirRecurse(stagingDir);

		foreach (idx; 0 .. entryCount)
		{
			auto fileName = buildPath(stagingDir, format("entry-%02d.txt", idx));
			std.file.write(fileName, "archive entry " ~ idx.to!string);
		}

		auto rc = executeShell("zip -q \"%s\" %s/*".format(fnMany, stagingDir));
		write(rc.output);
		assert(rc.status == 0, rc.output);
	}

	createTestArchive();
	scope (success)
		deleteTestArchive();

	auto fh1 = File(fn);
	auto dco1 = new NamedBinaryBlob(fn, fh1.size, SysTime(4_237_892));
	updateArchives(dco1, true);
	assert(dco1.archiveSpecs.length > 0);

	createManyEntriesArchive(11);
	scope (success)
		deleteManyEntriesArchive();

	auto fh2 = File(fnMany);
	auto dco2 = new NamedBinaryBlob(fnMany, fh2.size, SysTime(4_237_892));
	updateArchives(dco2, true);
	assert(dco2.archiveSpecs.length >= 11,
		"Expected all archive entries to be scanned for archives with more than 10 files.");
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
		import std.algorithm.sorting : sort;
		import std.file : exists;

		if (obj.fileSize) // Empty files surely have no info at all....
		{
			auto filespecs = obj.fileSpecs.sort;
			foreach (spec; filespecs)
			{
				try
				{
					obj.torrentInfo = getTorrentInfo(spec.fileName);
				}
				catch (Exception e)
				{
					logFLine("\nCannot analyse torrent: %s", e.msg);
				}
				break;
			}
		}
	}
}

@("updateTorrentInfo")
unittest
{
	import std.stdio : File;

	string filename = "./test/example.torrent";
	auto fh = File(filename);
	auto dco = new NamedBinaryBlob(filename, fh.size, SysTime(4_237_892));
	updateTorrentInfo(dco, true);
	assert(dco.torrentInfo, "No TorrentInfo was set.");
	assert(dco.torrentInfo.isMultiFile == false);

	string filename2 = "./test/test-multifile.torrent";
	auto fh2 = File(filename2);
	auto dco2 = new NamedBinaryBlob(filename2, fh2.size, SysTime(4_237_892));
	updateTorrentInfo(dco2, true);
	assert(dco2.torrentInfo, "No TorrentInfo was set.");
	assert(dco2.torrentInfo.isMultiFile == true);

}

/** Merge identical binblobs into a new combined object
 *
 * objs - list of identical(!) objects
 */
NamedBinaryBlob mergeDataClassObjects(NamedBinaryBlob[] objs)
{
	import std.algorithm.iteration : uniq;

	enforce(objs.length >= 2, "Need at least 2 objects");
	MediaInfoSig mis = null;
	assert(objs.filter!(a => a.checkSums.hasDigests).array.length, "Missing checksums?");

	foreach (obj; objs[1 .. $])
	{
		enforce(objs[0] == obj, "Objects not identical.\n%s\n%s\n"
				.format(objs[0].toString, obj.toString));
		if (!mis)
			mis = obj.mediaInfoSig;
		else
			enforce(mis == obj.mediaInfoSig, "Mismatching MediaInfoSig");
	}

	auto newobj = (objs[0]).dup;
	newobj.mediaInfoSig = mis;
	foreach (o; objs[1 .. $])
		newobj.fileSpecs ~= o.fileSpecs;
	newobj.fileSpecs = newobj.fileSpecs.uniq!("a.fileName == b.fileName", FileSpec[]).array;
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

/** Remove Cleanup list
 *
 * Params:
 *   objs = Set of objects to cleanup
 * Returns: cleaned up array
 */
NamedBinaryBlob[] cleanupDataClassObjs(NamedBinaryBlob[] objs)
{
	import std.array;
	import std.algorithm : filter;

	alias matcher = (a) => !a.isBlobOrphaned;
	auto valobjs = objs.filter!(matcher);
	return valobjs.array;
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

	// Test fixups for (de)serialisation
	auto dcobjs2 = fixupDataClassArrayOut(dcobjs1);
	auto dcobjs3 = fixupDataClassArrayIn(dcobjs2);

	// test deletion of nodes from array
	invalidateDataClassObjs(dcobjs3);
	auto dcobj4 = cleanupDataClassObjs(dcobjs3);
	assert(dcobj4.length == 0);
}
